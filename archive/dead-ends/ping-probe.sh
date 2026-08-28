#!/usr/bin/env bash
# Read the live SoundWire PING status for links 1 and 2, to settle whether the
# second amplifier on each link (:a, :9) is physically present on the bus at all.
#
# Mechanism: tas2783_sdca_dev_resume() (sound/soc/codecs/tas2783-sdw.c:1081-1095,
# v7.1.9) waits on slave->initialization_complete and, on timeout, calls
# sdw_show_ping_status(bus, true) -- which dev_dbg()s the raw two-bits-per-device
# PING bitmap from CDNS_MCP_SLAVE_STAT (bus.c:313-338, cadence_master.c:816).
# Opening the Speaker PCM forces that resume, so the bitmap lands in dmesg.
#
# READ-ONLY apart from dynamic-debug flags (which reset on reboot) and one failed
# PCM open. Nothing is unbound; nothing is written to disk; the SOF card is not
# torn down. Revert = reboot, or just rerun with the flags cleared.
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "run me with sudo" >&2; exit 1; }

DBG=/sys/kernel/debug/dynamic_debug/control
MODS=(soundwire_bus soundwire_cadence soundwire_intel snd_soc_tas2783_sdw)

echo "== state before =="
for d in /sys/bus/soundwire/devices/sdw:0:[12]:*/; do
  printf '  %-32s status=%-11s dev_num=%-4s rt=%s\n' \
    "$(basename "$d")" "$(cat "$d/status" 2>/dev/null)" \
    "$(cat "$d/device_number" 2>/dev/null)" "$(cat "$d/power/runtime_status" 2>/dev/null)"
done

echo
echo "== Cadence PING status straight from the registers =="
for l in 1 2 3; do
  f=$(ls -d /sys/kernel/debug/soundwire/master-0-$l/intel-sdw/intel-registers 2>/dev/null)
  [[ -n $f ]] || { echo "  link $l: no debugfs (is CONFIG_SOUNDWIRE_INTEL debugfs on?)"; continue; }
  echo "  --- link $l"
  grep -iE "SLAVE_STAT|SLAVE_INTSTAT|MCP_STAT|MCP_CONFIG|MCP_CONTROL" "$f" 2>/dev/null | sed 's/^/    /'
done

echo
echo "== enabling dynamic debug =="
for m in "${MODS[@]}"; do
  echo "module $m +p" > "$DBG" 2>/dev/null && echo "  $m ok" || echo "  $m FAILED (not loaded?)"
done

MARK="ping-probe-$(date +%s)"
echo "$MARK" > /dev/kmsg

echo
echo "== forcing a Speaker PCM open (expected to fail with -22; that is the point) =="
timeout 25 aplay -D hw:1,2 -f S32_LE -r 48000 -c 2 -d 1 /dev/zero 2>&1 | sed 's/^/  /'
echo "  aplay exit: $?"
sleep 2

echo
echo "== kernel log since the marker =="
dmesg --notime | sed -n "/$MARK/,\$p" | grep -vE "^$MARK" | sed 's/^/  /'

echo
echo "== the line that matters =="
dmesg --notime | sed -n "/$MARK/,\$p" | grep -iE "PING status|no peripherals attached" | sed 's/^/  /' || echo "  (no PING status line -- resume did not reach the timeout path)"

echo
echo "== disabling dynamic debug again =="
for m in "${MODS[@]}"; do echo "module $m -p" > "$DBG" 2>/dev/null; done

echo
echo "== state after =="
for d in /sys/bus/soundwire/devices/sdw:0:[12]:*/; do
  printf '  %-32s status=%-11s dev_num=%-4s rt=%s\n' \
    "$(basename "$d")" "$(cat "$d/status" 2>/dev/null)" \
    "$(cat "$d/device_number" 2>/dev/null)" "$(cat "$d/power/runtime_status" 2>/dev/null)"
done
echo
echo "== card still present =="; aplay -l 2>&1 | grep -E "^card 1" | sed 's/^/  /' || echo "  CARD 1 GONE (unexpected -- reboot)"
