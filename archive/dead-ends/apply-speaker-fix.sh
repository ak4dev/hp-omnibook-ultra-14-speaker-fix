#!/usr/bin/env bash
# Bring up the internal speakers on an HP Panther Lake laptop whose BIOS omits
# the SDCA function-type DisCo constant for its TI TAS2783 amplifiers.
#
# Three independent defects, in the order they bite:
#
#   1. BIOS: mipi-sdca-control-dc-value is missing from each amplifier's
#      mipi-sdca-control-0x5-subproperties, so find_sdca_function() rejects all
#      four and no amplifier DAI link is ever built. Fixed here by rebuilding
#      snd-soc-sdca with a five-line change that assumes SmartAmp for a TI
#      (mfg 0x0102) peripheral whose DC value is unreadable. Two people have
#      reported sound from exactly this change on sibling HP boards
#      (thesofproject/linux#5760, Launchpad #2143870).
#   2. Firmware naming: Linux 7.1 asks for <ssid>-<link>-<uid>.bin while
#      linux-firmware ships <ssid>-<link>-0x<uid>.bin, so the amplifier DSP is
#      never programmed and tas_sdw_hw_params refuses playback with -EINVAL.
#      Fixed by omnibook-speaker-firmware.
#   3. UCM has no tas2783 profile, so even with a working Speaker PCM the
#      higher layers may not expose it. Handled last, and only if needed.
#
# NOTHING here touches the boot path. snd-soc-sdca is a loadable module
# (0 hits in modules.builtin), module signature enforcement is off
# (CONFIG_MODULE_SIG_FORCE unset, sig_enforce=N), lockdown is [none] and
# Secure Boot is off — so the worst case is no audio until the stock module is
# restored, never a machine that will not boot. Revert: see --revert.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/sdca-build"
KVER="$(uname -r)"
STOCK="/lib/modules/$KVER/kernel/sound/soc/sdca/snd-soc-sdca.ko.zst"
BACKUP="/lib/modules/$KVER/kernel/sound/soc/sdca/snd-soc-sdca.ko.zst.stock"

# omnibook-speaker-firmware, wherever it is. Under sudo neither PATH nor $HOME
# is the invoking user's, and stage_bin may not have copied it to ~/.local/bin
# yet — it needs no @OMNIBOOK_DIR@ substitution, so the checkout copy runs fine.
find_fw_tool() {
    local home="" c
    [[ -n ${SUDO_USER:-} ]] && home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    for c in "$(command -v omnibook-speaker-firmware 2>/dev/null || true)" \
             "${home:-$HOME}/.local/bin/omnibook-speaker-firmware" \
             "${home:-$HOME}/.omnibook/bin/omnibook-speaker-firmware" \
             "${OMNIBOOK_DIR:-}/bin/omnibook-speaker-firmware"; do
        [[ -n $c && -x $c ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf 'apply-speaker-fix: %s\n' "$*" >&2; exit 1; }

# Defect 2 alone, with no build and no reboot. snd_soc_tas2783_sdw has refcount
# 0, so it can be cycled in place and the amplifiers re-request their firmware
# immediately. This isolates the firmware question from the ACPI one: if the
# blobs will not download over SoundWire, that is worth knowing before building
# and installing a kernel module for a defect further up the chain.
firmware_only() {
    say "Firmware links only (no build, no reboot)"
    local tool; tool=$(find_fw_tool) || die "cannot find omnibook-speaker-firmware"
    info "using $tool"
    "$tool" link
    say "Cycling snd_soc_tas2783_sdw"
    local since; since=$(date '+%Y-%m-%d %H:%M:%S')
    modprobe -r snd_soc_tas2783_sdw || die "could not unload snd_soc_tas2783_sdw"
    modprobe snd_soc_tas2783_sdw    || die "could not reload snd_soc_tas2783_sdw"
    sleep 3
    say "What the amplifiers did"
    journalctl -k --since "$since" --no-pager |
        grep -iE "tas2783|firmware|parity|dev_num|SCP" || info "(nothing logged)"
    cat <<'EOF'

   Read it like this:
     no "Direct firmware load ... failed" and no "FW download failed"
        -> defect 2 is cleared; the amplifiers now have their DSP program.
           Proceed to the module build (run this script with no arguments).
     "FW download failed: -5" / "fw with no files" / SoundWire NACKs
        -> the blobs are found but will not transfer. Stop: a kernel module
           for defect 1 will not help, and that needs investigating first.
   Revert: omnibook-speaker-firmware unlink
EOF
    exit 0
}
[[ ${1:-} == --firmware-only ]] && { [[ $(id -u) -eq 0 ]] || die "run this with sudo"; firmware_only; }

revert() {
    say "Reverting"
    [[ -f $BACKUP ]] && { mv -f "$BACKUP" "$STOCK"; info "stock snd-soc-sdca restored"; }
    depmod -a "$KVER"
    if tool=$(find_fw_tool); then "$tool" unlink || true; fi
    info "reboot to return to the stock stack"
    exit 0
}
[[ ${1:-} == --revert ]] && revert

[[ $(id -u) -eq 0 ]] || die "run this with sudo"
[[ -d $BUILD ]] || die "missing $BUILD (the patched sources)"

# ---------------------------------------------------------------- preflight
say "Preflight"
grep -q snd_soc_sdca "/lib/modules/$KVER/modules.builtin" &&
    die "snd-soc-sdca is built in on this kernel — this approach only works when it is a module"
[[ $(cat /sys/module/module/parameters/sig_enforce 2>/dev/null) == N ]] ||
    die "module signature enforcement is on — an unsigned module will not load"
grep -q "^\[none\]" /sys/kernel/security/lockdown 2>/dev/null ||
    info "WARNING: kernel lockdown is not [none]; module loading may be restricted"
info "kernel $KVER, unsigned modules loadable"

# ------------------------------------------------------------------- build
say "Building the patched snd-soc-sdca"
[[ -d /lib/modules/$KVER/build ]] || die "linux-headers for $KVER is not installed (omarchy pkg add linux-headers)"
# Kbuild writes .cmd files beside each object and cannot overwrite one owned by
# another user, so a build that has been run both ways leaves the tree wedged.
# Start clean rather than diagnose it twice.
make -C "$BUILD" clean >/dev/null 2>&1 || true
rm -f "$BUILD"/*.o "$BUILD"/.*.cmd "$BUILD"/*.ko "$BUILD"/*.mod "$BUILD"/*.mod.c \
      "$BUILD"/Module.symvers "$BUILD"/modules.order "$BUILD"/.module-common.o 2>/dev/null || true
make -C "$BUILD" >/dev/null || die "module build failed"
[[ -f $BUILD/snd-soc-sdca.ko ]] || die "no module produced"
info "built $(stat -c%s "$BUILD/snd-soc-sdca.ko") bytes"
modinfo "$BUILD/snd-soc-sdca.ko" | grep -q "vermagic:.*$KVER" ||
    die "vermagic mismatch — built against the wrong headers"
info "vermagic matches the running kernel"
# rt712-sdca, tas2783-sdw, soundwire_bus and the Intel SDCA quirks module all
# resolve symbols out of this one. A build that dropped an export would take
# the working headset path down with it, so refuse rather than find out later.
tmp_stock=$(mktemp --suffix=.ko)
trap 'rm -f "$tmp_stock"' EXIT
zstd -qdf "$STOCK" -o "$tmp_stock" 2>/dev/null || die "could not decompress the stock module"
stock_syms=$(nm "$tmp_stock" 2>/dev/null | grep -c __ksymtab_ || true)
new_syms=$(nm "$BUILD/snd-soc-sdca.ko" 2>/dev/null | grep -c __ksymtab_ || true)
[[ $stock_syms -gt 0 && $new_syms -eq $stock_syms ]] ||
    die "export mismatch: stock has $stock_syms, build has $new_syms — refusing to install"
info "$new_syms exported symbols, matching the stock module"

# ----------------------------------------------------------------- install
say "Installing"
[[ -f $BACKUP ]] || cp -a "$STOCK" "$BACKUP"
info "stock module saved at $BACKUP"
zstd -q -f -19 "$BUILD/snd-soc-sdca.ko" -o "$STOCK"
depmod -a "$KVER"
info "patched module installed and depmod run"

# ------------------------------------------------------- amplifier firmware
say "Amplifier firmware names"
if tool=$(find_fw_tool); then
    info "using $tool"
    "$tool" link
else
    info "omnibook-speaker-firmware not found — skipping (defect 2 will bite at playback)"
fi

say "Done — reboot, then check:"
cat <<'EOF'
   journalctl -k -b 0 | grep -E "SDCA function|DisCo constant|loading topology"
       want: "SDCA function SmartAmp" lines instead of "DisCo constant" ones,
             and a sof-sdca-2amp-id2.tplg among the topologies loaded
   aplay -l | grep -i speaker
       want: a Speaker device on card 0
   pactl list cards | grep alsa.components
       want: cfg-amp:2 (it counts SoundWire links, not amplifiers) and a spk: token
   speaker-test -D hw:0,<N> -c 2 -t sine -l 1
       where <N> is the Speaker device number from aplay -l

   If a Speaker PCM exists but nothing routes to it, the remaining piece is a
   UCM profile: /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf, modelled on
   rt1320.conf in the same directory.

   Revert everything:  sudo bash apply-speaker-fix.sh --revert
EOF
