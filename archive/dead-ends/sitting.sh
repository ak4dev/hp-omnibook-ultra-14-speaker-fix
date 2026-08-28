#!/usr/bin/env bash
# One attended sitting: install the endpoint-filter snd-soc-sdw-utils.ko and the
# hda-loader instrumentation, then reboot.  See STATE.md sections 5 (RANK 2 + RANK 3)
# and 2.5.  Root only -- sudo needs a physical FIDO2 touch, and so does the reboot,
# because the root filesystem is FIDO2-unlocked too.
#
#   sudo ./sitting.sh install     module + dyndbg
#   sudo ./sitting.sh revert      stock module + drop dyndbg
#   ./sitting.sh verify           read the result (no root)
set -euo pipefail

KVER=7.1.9-arch1-2
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST=/lib/modules/$KVER/kernel/sound/soc/sdw_utils/snd-soc-sdw-utils.ko.zst
BUILT=$HERE/snd-soc-sdw-utils.ko
DBG=/etc/modprobe.d/omnibook-sdw-debug.conf

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
need_root() { [[ $EUID -eq 0 ]] || { echo "needs root: sudo $0 $*" >&2; exit 1; }; }

# Never `zstd -o` straight over a live .ko.zst: an interrupted run leaves a truncated
# archive where the kernel will look for the module, and the failure is silent.
install_module() {
  local tmp="$DEST.new" vm
  [[ -f $BUILT ]] || { warn "no module at $BUILT -- run make first"; return 1; }
  vm=$(modinfo "$BUILT" | sed -n 's/^vermagic: *//p')
  [[ $vm == "$KVER"* ]] || { warn "vermagic mismatch: '$vm' is not $KVER"; return 1; }
  zstd -q -f -19 "$BUILT" -o "$tmp" || { warn "compress failed"; rm -f "$tmp"; return 1; }
  zstd -t "$tmp" 2>/dev/null || { warn "compressed module does not verify"; rm -f "$tmp"; return 1; }
  if [[ ! -f $DEST.stock ]]; then
    cp -a "$DEST" "$DEST.stock" || { warn "could not keep a stock copy"; rm -f "$tmp"; return 1; }
    ok "kept stock snd-soc-sdw-utils.ko.zst as .stock"
  else
    ok ".stock already present, left untouched"
  fi
  mv -f "$tmp" "$DEST"
  ok "installed snd-soc-sdw-utils.ko.zst ($(stat -c%s "$DEST") bytes)"
}

add_dbg() {
  grep -q snd_sof_intel_hda_common "$DBG" 2>/dev/null && { ok "hda dyndbg already present"; return; }
  cat >> "$DBG" <<'EOF'

# omnibook RANK 2: the two markers that place the detach inside the code-loader DMA
# or inside the FW_READY wait -- "Attempting iteration %d of Core En/ROM load" and
# "Firmware download successful" live in snd_sof_intel_hda_common, which has never
# been instrumented.  Log volume only; remove these two lines to revert.
options snd_sof_intel_hda_common dyndbg=+p
options snd_sof_intel_hda_generic dyndbg=+p
EOF
  ok "added hda-loader dyndbg to $DBG"
}

drop_dbg() {
  [[ -f $DBG ]] || return 0
  sed -i '/omnibook RANK 2/,+5d; /^options snd_sof_intel_hda_common dyndbg/d; /^options snd_sof_intel_hda_generic dyndbg/d' "$DBG"
  ok "removed hda-loader dyndbg"
}

case "${1:-}" in
install)
  need_root install
  say "Installing the endpoint filter and the hda-loader instrumentation"
  install_module
  add_dbg
  depmod -a "$KVER" && ok "depmod done"
  say ""
  say "Now: sudo reboot   (be at the console -- FIDO2 unlocks the root filesystem)"
  say "After login:       $HERE/sitting.sh verify"
  ;;
revert)
  need_root revert
  say "Reverting THIS experiment only (not omnibook-speaker-fix revert, which is a"
  say "full teardown and would also remove the working defect-1 SDCA module)"
  if [[ -f $DEST.stock ]]; then mv -f "$DEST.stock" "$DEST"; ok "restored stock snd-soc-sdw-utils.ko.zst"
  else ok "no .stock -- nothing to restore"; fi
  drop_dbg
  depmod -a "$KVER" && ok "depmod done"
  say ""
  say "Now: sudo reboot"
  ;;
verify)
  say "== did the filter run? =="
  journalctl -k -b 0 --no-pager 2>/dev/null | grep -E "omnibook:" || echo "  (no omnibook lines -- filter did not drop anything, or module not active)"
  say ""
  say "== amps =="
  for d in /sys/bus/soundwire/devices/sdw:0:*:0102:0000:*; do
    [[ -e $d/status ]] || continue
    printf '  %-34s %-11s rt=%s\n' "$(basename "$d")" "$(cat "$d/status")" \
      "$(cat "$d/power/runtime_status" 2>/dev/null)"
  done
  say ""
  say "== cfg-amp and the Speaker PCM =="
  grep -o 'cfg-amp:[0-9]*' /proc/asound/card1/../../*/components 2>/dev/null || \
    awk '/components/{print "  "$0}' <(alsactl info 2>/dev/null | grep -A1 sofsoundwire | grep components) 2>/dev/null || true
  aplay -l 2>/dev/null | grep -i speaker | sed 's/^/  /' || echo "  no Speaker PCM"
  say ""
  say "== RANK 2: which side of the code loader did the detach fall on? =="
  journalctl -k -b 0 -o short-precise --no-pager 2>/dev/null | grep -E \
    "booting DSP firmware|Attempting iteration|Core En/ROM load|Firmware download successful|firmware boot complete|Booted firmware version|Slave status change: 0x1[0-9]0" \
    | sed 's/^/  /'
  say ""
  say "== does it make sound? =="
  say "  speaker-test -D hw:1,2 -c 2 -r 48000 -F S32_LE -t sine -l 1"
  ;;
*)
  echo "usage: $0 {install|revert|verify}" >&2; exit 2;;
esac
