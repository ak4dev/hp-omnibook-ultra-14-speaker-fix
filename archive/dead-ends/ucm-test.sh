#!/usr/bin/env bash
# Build a merged UCM tree (stock + our tas2783 overlay) in a temp dir and test it
# as an unprivileged user. No root, no writes outside $TMPDIR, nothing touched
# in /usr or /var.
#
# alsa-lib 1.2.16.1 honours $ALSA_CONFIG_UCM2 as a full replacement for
# /usr/share/alsa/ucm2, so the whole UCM last mile is testable as uid 1000.
set -euo pipefail

: "${CARD:=1}"
: "${STOCK:=/usr/share/alsa/ucm2}"
OVERLAY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ucm"
TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT

cp -r "$STOCK" "$TREE/ucm2"
chmod -R u+w "$TREE/ucm2"
cp -r "$OVERLAY/." "$TREE/ucm2/"
export ALSA_CONFIG_UCM2="$TREE/ucm2"

echo "== card components (source of every UCM variable) =="
amixer -c "$CARD" info | sed -n 's/^  Components\t: //p'

echo
echo "== syntax check: alsaucm dump text =="
if alsaucm -c "hw:$CARD" dump text >/dev/null 2>"$TREE/err"; then
	echo "OK (exit 0, stderr empty: $([ -s "$TREE/err" ] && cat "$TREE/err" || echo yes))"
else
	echo "FAILED"; cat "$TREE/err"; exit 1
fi

echo
echo "== UCM devices in verb HiFi =="
alsaucm -c "hw:$CARD" list _devices/HiFi

echo
echo "== ctl remap produced for the speaker mixer element =="
alsaucm -c "hw:$CARD" get _alibcfg | sed -n '/^ctl.default/,/^pcm\./p' | sed -n '/map {/,/^\t}/p'

echo
echo "== does the virtual element bind to real controls? =="
cat >"$TREE/remap.conf" <<EOF
<$( [ -f /usr/share/alsa/alsa.conf ] && echo /usr/share/alsa/alsa.conf )>
ctl.remaptest {
	type remap
	child { type hw
		card $CARD
	}
$(alsaucm -c "hw:$CARD" get _alibcfg | sed -n '/^ctl.default/,/^pcm\./p' | sed -n '/^\tmap {/,/^\t}/p')
}
EOF
ALSA_CONFIG_PATH="$TREE/remap.conf" amixer -D remaptest sget 'tas2783 Speaker' 2>&1 ||
	echo "(virtual element not resolvable -- amps may be detached)"
