#!/usr/bin/env bash
# Re-run tas_io_init() on a fully-booted SoundWire bus.
#
# sdw_bus_probe() calls drv->ops->update_status(slave, slave->status) at the end of
# probe (v7.1.9 drivers/soundwire/bus_type.c:148), so unbinding and re-binding an
# ATTACHED peripheral re-enters tas_update_status() -> tas_io_init(), which redoes the
# SW reset and the firmware download. At boot that download failed with -61 (-ENODATA,
# "peripheral did not ACK") ~90 ms BEFORE the SOF DSP finished booting. If it succeeds
# now, the boot failure is an ordering race and is fixable. If it fails the same way,
# the amps genuinely refuse the paged write and this needs a different attack.
#
# Read-only apart from: dynamic-debug flags (reset on reboot) and the unbind/bind.
# Nothing is written to disk. Revert = reboot.
#
# Risk: unbinding an ASoC codec component can tear down card 1 (sof-soundwire).
# Rebinding normally brings it back. Internal speakers do not work either way; a
# reboot restores everything. USB audio (card 0) is unaffected.
set -uo pipefail

DBG=/sys/kernel/debug/dynamic_debug/control
OUT=${1:-/tmp/tas2783-probe.log}
DRV=/sys/bus/soundwire/drivers/slave-tas2783

[[ $EUID -eq 0 ]] || { echo "run me with sudo" >&2; exit 1; }

echo "== enabling dynamic debug =="
for m in snd_soc_tas2783_sdw soundwire_bus soundwire_cadence soundwire_intel snd_soc_sdca; do
  echo "module $m +p" > "$DBG" 2>/dev/null && echo "  $m ok" || echo "  $m FAILED"
done

echo
echo "== state before =="
for d in /sys/bus/soundwire/devices/sdw:0:[12]:*/; do
  printf '  %-32s %s\n' "$(basename "$d")" "$(cat "$d/status" 2>/dev/null)"
done

: > "$OUT"
dmesg -w --time-format=iso >> "$OUT" &
WPID=$!
sleep 1

for dev in sdw:0:1:0102:0000:01:d sdw:0:2:0102:0000:01:c; do
  st=$(cat "/sys/bus/soundwire/devices/$dev/status" 2>/dev/null)
  if [[ $st != Attached ]]; then
    echo "== skipping $dev (status=$st, bind would not reach tas_io_init) =="
    continue
  fi
  echo "== unbind $dev =="
  echo "$dev" > "$DRV/unbind" 2>&1 || echo "  unbind failed"
  sleep 2
  echo "== bind $dev =="
  echo "$dev" > "$DRV/bind" 2>&1 || echo "  bind failed"
  sleep 4
done

sleep 2
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null

echo
echo "== state after =="
for d in /sys/bus/soundwire/devices/sdw:0:[12]:*/; do
  printf '  %-32s %s\n' "$(basename "$d")" "$(cat "$d/status" 2>/dev/null)"
done

echo
echo "== verdict =="
if grep -q "FW download failed" "$OUT"; then
  echo "  FAILED again: $(grep -c 'FW download failed' "$OUT") x 'FW download failed'"
  grep -E "FW download failed|fw with no files" "$OUT" | tail -6
elif grep -qE "daddr=0x" "$OUT"; then
  echo "  *** FIRMWARE DOWNLOAD SUCCEEDED *** (per-file dev_dbg lines present, no failure)"
  grep -E "daddr=0x" "$OUT" | head -8
else
  echo "  inconclusive - no FW download attempt seen in the captured window"
fi
echo
echo "  card still present:"; aplay -l 2>&1 | grep -E "^card 1" || echo "    CARD 1 GONE - 'modprobe -r snd_soc_sof_sdw && modprobe snd_soc_sof_sdw' or reboot"

echo
echo "== full kernel log captured to $OUT ($(wc -l < "$OUT") lines) =="
