# HP OmniBook Ultra Laptop 14 — internal speakers on Linux (TAS2783 / SoundWire)

> ### ⚠️ Incomplete fix: left speaker only
> This restores sound from the **left-hand speaker pair only**. The right-hand pair cannot
> be recovered by anything in this repo — it is a separate, unfixed kernel/hardware defect
> (see [defect 4](docs/defects.md#defect-4--the-amplifiers-leave-the-bus-and-never-return-worked-around-not-fixed)).
> Applying this fix does **not** restore stereo sound. Read "What you get, honestly" below
> before you start.

**Symptom:** the laptop's internal speakers produce nothing on Linux. There is no
`Speaker` ALSA device at all, `pactl` offers no speaker sink, the sound card sits at
profile `off` with a null sink, and the kernel log carries:

```
acpi device:NN: function type only supported as DisCo constant
Direct firmware load for 8EB4-1-A.bin failed with error -2
slave-tas2783 sdw:0:1:...:a: FW download failed: -61
slave-tas2783 sdw:0:1:...:a: error playback without fw download
```

Headphones, HDMI and USB audio all work. Only the built-in speakers are dead.

**Machine:** HP OmniBook Ultra Laptop 14-kd0xxx, board / PCI-subsystem id `8EB4`, Intel
Core Ultra (Panther Lake, SOF ACE 3.0), four TI **TAS2783** SoundWire smart amplifiers
plus an RT712 headset codec. Developed on Arch Linux, kernel 7.1.9, linux-firmware
20260810, sof-firmware 2025.12.2, alsa-ucm-conf 1.2.16.1, BIOS Insyde F.06.

Every board-specific value — PCI subsystem id, link numbers, amplifier unique ids, the
ALSA card index — is **derived at runtime**, so this should apply unchanged to the sibling
HP chassis that report the same defect (`8EA1`–`8EB4`, `8EF6`, `9001`, EliteBook X).

---

## Does this apply to my machine?

```bash
./bin/omnibook-speaker-fix check          # no root, changes nothing
```

Affected if TAS2783 peripherals are present, there is **no** `Speaker` PCM, and the log
carries `function type only supported as DisCo constant`.

## Quick start

```bash
sudo ./bin/omnibook-speaker-fix install   # firmware links, two patched modules, tracing
sudo reboot                               # be at the console; see "Safety" below
./bin/omnibook-speaker-fix userspace      # as your normal user, NOT with sudo
./bin/omnibook-speaker-fix verify
```

`./bin/omnibook-speaker-fix revert` undoes the system half. Nothing here touches the boot
path; the worst case is no audio until you revert.

---

## What you get, honestly

**Mono, from the left-hand pair.** Two of the four amplifiers leave the SoundWire bus
during the audio DSP's firmware boot and never come back, and on this chassis the ones
that die are the right-side pair. The fix makes the survivors play; it does not recover
the dead ones, and **that half is not fixable locally** — it needs a BIOS or a kernel
change from HP/TI. See [docs/defects.md](docs/defects.md) defect 4 and
[docs/upstream.md](docs/upstream.md).

Do not expect stereo. Do not expect all four amps.

## What is actually broken — four defects, stacked

Each one alone is enough to kill the speakers, and clearing one only reveals the next.
Full analysis in [docs/defects.md](docs/defects.md).

| # | Defect | Status |
|---|---|---|
| 1 | **BIOS/ACPI**: the DSDT omits `mipi-sdca-control-dc-value`, so `find_sdca_function()` drops every amplifier — no amp DAI link, no `Speaker` PCM, `cfg-amp:0` | **Fixed** by an out-of-tree `snd-soc-sdca.ko` that assumes SmartAmp for a TI peripheral whose DC value is unreadable |
| 2 | **Firmware naming**: Linux ≤ 7.1 asks for `8EB4-1-A.bin`; linux-firmware ships `8EB4-1-0xA.bin.zst`. Every load is `-ENOENT` and playback then fails `-EINVAL` | **Fixed** by symlinks in `/usr/lib/firmware/updates/`. Retires itself on Linux ≥ 7.2 (`e26bb459d0f3`) |
| 3 | *"the firmware download races the DSP boot"* | **Does not exist as diagnosed.** The premise was disproven; see defect 3 |
| 4 | **Amplifiers leave the bus** ~3 ms before `firmware boot complete` and never return. One dead amp's latched `runtime_error` aborts the `Speaker` PCM open for *all* of them | **Worked around, not fixed**: a patched `snd-soc-sdw-utils.ko` drops the dead endpoints so the survivors play |

Clearing 1, 2 and 4 gives you a working `Speaker` PCM. It does **not** give you a sink —
PipeWire's ACP layer builds no `HiFi` profile for this card, so the card stays at profile
`off`. The userspace half ([docs/userspace.md](docs/userspace.md)) is what turns the PCM
into a working default sink.

---

## Safety, and one operational warning

Nothing here touches the boot path. Both replaced modules are loadable (`MODULES=()` in
`mkinitcpio.conf`, no soundwire in the autodetect set, so no initramfs is involved), the
pristine modules are kept as `.stock` beside them, and `revert` puts them back. Worst case
is no audio until you revert — USB audio is unaffected either way.

The patched modules are **unsigned** and will taint the kernel. That is fine where
`CONFIG_MODULE_SIG_FORCE` is unset and Secure Boot is off; check with
`cat /sys/kernel/security/lockdown` and `mokutil --sb-state` first.

> **A kernel upgrade silently destroys both out-of-tree modules.** New `vermagic`, and
> pacman owns those paths — `pacman -Qkk linux` reports them as mismatches. The next
> unheld `-Syu` plus a reboot takes both modules and the speakers with them. Read
> [docs/porting.md](docs/porting.md) **before** your next system upgrade.

Also read [docs/traps.md](docs/traps.md) before debugging anything here. Several failure
modes in this stack are unrecoverable without a reboot — a wedged PCM that escalates to
unkillable D-state processes, a `context.objects` entry that kills the whole PipeWire
daemon, a card unbind that takes HDMI with it. Each one cost a session once.

**These amplifiers cannot be tested with short tone bursts.** The TAS2783 smart-amp
algorithm gates them out. Always use a frequency sweep of **≥ 5 seconds**, and treat any
"silent" result from a burst as unproven.

---

## Layout

```
bin/
  omnibook-speaker-fix        install / check / verify / revert — the entry point
  omnibook-speaker-report     one-screen verdict per boot, written to /var/log
  omnibook-speaker-mixer      restores the amp mixer state at session start (no root)
  omnibook-tas2783-late       deferred modprobe (defect 3; see the caveat)
  omnibook-sdw-trace          dyndbg arm/disarm + enumeration trace report
  omnibook-ucm-overlay        the ALSA UCM last mile — optional, see docs/ucm.md
kernel/
  sdca/                       defect 1: the patch that makes the amps parse
  sdw-utils/                  defect 4: the endpoint filter that makes them play
  cadence/                    experiment: re-arm the attach rescan (built, never installed)
  sof-sdw-order/              experiment: start the links after the DSP boots (never installed)
userspace/
  alsa/ pipewire/ systemd/    the sink, the channel summing, the mixer restore
  modprobe.d/                 the deferral and the trace
  ucm/                        the tas2783 UCM overlay sources
docs/
  defects.md                  the four defects, in detail
  userspace.md                what actually delivers sound, and why it is shaped this way
  ucm.md                      the UCM overlay: why it is installed and why it is inert
  traps.md                    every mistake that cost a session — read before debugging
  experiments.md              the two module swaps that are NOT part of `install`
  porting.md                  surviving a kernel upgrade
  upstream.md                 what to file, where, and how not to get it dismissed
  investigation.md            the full research record, session by session
archive/
  boots/                      preserved kernel logs from the decisive boots (scrubbed)
  evidence/                   sysfs/PCM snapshots and the SOF topology dumps
  dead-ends/                  probes that did not work, kept for the notes in traps.md
  state-history/              earlier revisions of the research record
```

## Credit and licence

No licence file: default copyright applies. Published so the next person who searches for
*"HP OmniBook Ultra 14 speakers not working Linux"* or *"TAS2783 DisCo constant"* finds
something. The kernel patches under `kernel/` are derivatives of GPL-2.0 kernel sources and
carry that licence.
