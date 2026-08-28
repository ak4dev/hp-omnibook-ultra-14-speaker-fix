# Laptop speakers (TAS2783 SoundWire) — persistent state

**Last updated: 2026-08-27, session 4.** This file is the authoritative, reboot-surviving
record. It lives outside `/tmp` on purpose (`/tmp` is tmpfs here). Read it first.

Companion documents in this directory:
- `FIX.md` — the standalone, portable fix: what to do on a *new* device, from scratch.
- `probe-fw-download.sh` — the live retry experiment (see "The decisive experiment").
- `apply-speaker-fix.sh` — build + install the patched SDCA module, manage firmware links.

---

## 1. The machine, and how to tell whether another one is affected

HP OmniBook Ultra Laptop 14-kd0xxx, board / PCI-subsystem id **`8EB4`**, Intel Panther Lake
(SOF ACE 3.0). Four TI TAS2783 SoundWire amplifiers — link 1 uids `a`,`d`; link 2 uids `9`,`c`
— plus an RT712 headset codec on link 3. Arch Linux, **kernel 7.1.9-arch1-2**,
linux-firmware 20260810-2, sof-firmware 2025.12.2-1, BIOS Insyde F.06 (2026-06-25).

Fingerprint a candidate machine with:
```bash
cat /sys/class/dmi/id/product_name /sys/class/dmi/id/board_name
ls /sys/bus/soundwire/devices/            # sdw:0:<link>:0102:0000:01:<uid> == TAS2783
journalctl -k -b 0 | grep -iE "tas2783|DisCo constant|SmartAmp|FW download"
aplay -l | grep -i speaker
```
Affected if: TAS2783 peripherals present, **no** `Speaker` PCM, and the log carries
`function type only supported as DisCo constant`.

---

## 2. Four stacked, independent defects

### Defect 1 — ACPI/SDCA function type. **SOLVED HERE (out-of-tree module).**
The OEM DSDT omits `mipi-sdca-control-dc-value` from each amplifier's
`mipi-sdca-control-0x5-subproperties`, so `find_sdca_function()` rejects all four amps
(`acpi device:NN: function type only supported as DisCo constant`). No amp SDCA function →
no amp DAI link → no `Speaker` PCM; the card parks at profile `off` with a null sink.
The lookup is byte-identical in 7.1, 7.2, mainline and linux-next, and **upstream has
declined the non-DC form on purpose** — this needs a BIOS fix or a local patch, for ever.

Fixed by a locally built out-of-tree `snd-soc-sdca.ko`: v7.1.9 `sound/soc/sdca/` verbatim
except `sdca_functions.c`, which assumes `SMART_AMP` for a TI peripheral
(`mfg_id 0x0102`, `part_id 0x0000`) whose DC value is unreadable.

**Status: INSTALLED and working.** `/lib/modules/7.1.9-arch1-2/kernel/sound/soc/sdca/`
holds `snd-soc-sdca.ko.zst` (956193 bytes, the patched one) with the stock module kept
beside it as `snd-soc-sdca.ko.zst.stock` (71503 bytes). Proof at cold boot:
```
acpi device:{20,22,24,26}: no DisCo constant for function type, assuming SmartAmp
                           SDCA function SmartAmp (type 1) at 0x1
slave-tas2783 sdw:0:1:...:a: Found Smart Amp function at index 0     (all four)
loading topology 0: intel/sof-ipc4-tplg/sof-sdca-2amp-id2.tplg
aplay -l  ->  card 1: sofsoundwire, device 2: Speaker (*)
```
The module is unsigned, so it taints the kernel (`module verification failed`). Harmless
here: `CONFIG_MODULE_SIG_FORCE` unset, `sig_enforce=N`, lockdown `[none]`, Secure Boot off.

### Defect 2 — firmware file naming. **SOLVED HERE (symlinks).**
Linux 7.1 builds the name `%04X-%1X-%1X.bin` from the PCI subsystem id, link and unique id
(`8EB4-1-A.bin`); linux-firmware 20260810 ships `8EB4-1-0xA.bin.zst`. Every load was
`-ENOENT`, so the amp DSP was never programmed.

Fixed by four symlinks in `/usr/lib/firmware/updates/` — the firmware loader's own override
directory, ahead of `/usr/lib/firmware` in `fw_path[]` and owned by no package:
```
8EB4-1-A.bin.zst -> ../ti/audio/tas2783/8EB4-1-0xA.bin.zst
8EB4-1-D.bin.zst -> ../ti/audio/tas2783/8EB4-1-0xD.bin.zst
8EB4-2-9.bin.zst -> ../ti/audio/tas2783/8EB4-2-0x9.bin.zst
8EB4-2-C.bin.zst -> ../ti/audio/tas2783/8EB4-2-0xC.bin.zst
```
Managed by `~/.omnibook/bin/omnibook-speaker-firmware` (`status` / `link` / `unlink`), which
derives every name at runtime from `/sys/bus/soundwire/devices`. Survives reboots and
linux-firmware upgrades. **Only needed on kernels < 7.2** — commit `e26bb459d0f3da`
("ASoC: tas2783: Update loaded firmware names to linux-firmware 20260519") makes 7.2 ask for
the `0x` name and fall back to the old one, so the script only ever adds links, never touches
a blob, and stands down once the plain name resolves.

**Status: APPLIED and working.** No `Direct firmware load ... failed` at cold boot.

### Defect 3 — the firmware download races the audio bring-up. **SOLVED (deferred module load).**

`tas_io_init()` runs from the SoundWire *attach* callback. On Intel ACE 2.0+ (Panther Lake is
ACE 3.0) the links are started early, in `hda_dsp_probe()` (`sound/soc/sof/intel/hda.c:911-918`,
v7.1.9), but **SoundWire interrupts are only enabled in `hda_dsp_post_fw_run()` (`hda.c:454`),
after the DSP firmware boots.** Every command issued in that window is answered
Command_Ignored, so the download failed with `-61` (`-ENODATA`) ~92 ms before the DSP booted.

Fixed by loading the codec module *after* the DSP boot line appears, so `sdw_bus_probe()` →
`update_status()` → `tas_io_init()` runs on a live bus. **Installed 2026-08-26 16:24, first
effective on the 16:25 boot.** Three root-owned files, none on the boot path:

| Path | What |
|---|---|
| `/etc/modprobe.d/omnibook-tas2783-defer.conf` | `blacklist snd_soc_tas2783_sdw` — stops the udev auto-load |
| `/etc/systemd/system/omnibook-tas2783-late.service` | oneshot, enabled, `Before=sound.target`, `TimeoutStartSec=45` |
| `/usr/bin/omnibook-tas2783-late` | polls `journalctl -k -b 0` for `Booted firmware version`, sleeps 1 s, `modprobe`s |

**Status: WORKING.** Proof at the 16:25 cold boot — compare against every earlier boot:

```
zero  "FW download failed"          (was 2 per boot)
zero  "Msg NACKed" / "trf on Slave" (was dozens)
zero  "Direct firmware load ... failed"
alsa.components:  cfg-amp:4         (was cfg-amp:0)
aplay -l:         card 1, device 2: Speaker (*)
amixer -c 1:      tas2783-1..4 Amp/Speaker Volume, Left/Right Spk, Left/Right Spk2
```

Revert: `rm` the three files, `systemctl disable omnibook-tas2783-late`, `depmod -a`.

**This is the fix STATE.md session 3 listed as candidate (A). It worked. The open risk that
`sof_sdw` might build a card without the Speaker DAI did not materialise — the four
`ASoC: Parent card not yet available, widget card binding deferred` lines are benign, and
the card is built once, complete, afterwards.**

### Defect 4 — only ONE amplifier per link attaches. **THE CURRENT WALL. NOT SOLVED.**

Exposed by defect 3's fix. On the 16:25 boot, with everything above working:

```
sdw:0:1:0102:0000:01:a   status=UNATTACHED   runtime=error   <- link 1, "second" amp
sdw:0:1:0102:0000:01:d   status=Attached     runtime=active
sdw:0:2:0102:0000:01:9   status=UNATTACHED   runtime=error   <- link 2, "second" amp
sdw:0:2:0102:0000:01:c   status=Attached     runtime=active
sdw:0:3:025d:0712:01     status=Attached                     (RT712 headset, fine)
```

The Speaker DAI runs through `:a`, so playback dies:

```
16:25:30 slave-tas2783 sdw:0:1:...:a: resume: initialization timed out
16:25:30 slave-tas2783 sdw:0:1:...:a: ASoC error (-22): at snd_soc_pcm_component_pm_runtime_get()
16:25:30  SDW1-Playback-SmartAmp: ASoC error (-22): at __soc_pcm_open()
16:25:30  Speaker: ASoC error (-22): at dpcm_be_dai_startup() / dpcm_fe_dai_startup()
```

**Established:**

- The failure is **silent**. Zero SoundWire errors on this boot — no `DEVID read fail`, no
  `Assign dev_num failed`, no NACK, no `Slave N initialization failed`, no parity, no `-61`.
  The second amp is simply never seen.
- `:a` and `:9` were **already UNATTACHED before the codec driver bound.** Timing, from
  `journalctl -o short-precise`: `:a` at 16:25:23.258814 and `:d` at 16:25:23.258972 — 158 µs
  apart. `sdw_bus_probe()` calls `update_status()` at the end of probe
  (`bus_type.c:148`); for an ATTACHED slave that blocks in `tas_io_init()` for the whole
  download, for an UNATTACHED one `tas_update_status()` returns at `tas2783-sdw.c:1208` in
  microseconds. `:d` then took **1.186 s** before `:9` probed; `:c` took **1.170 s** before
  the topology loaded. So the two that attached blocked ~1.2 s each, and the two that did not
  returned instantly. **The loss happens in the SoundWire core, with no codec driver loaded.**
- `tas_io_init()` (`tas2783-sdw.c:1136`) fires `request_firmware_nowait()` (`:1158`) and then
  **blocks** on `wait_event_timeout(fw_wait, fw_dl_task_done, TIMEOUT_FW_DL_MS)` (`:1168`),
  called synchronously from `tas_update_status()` (`:1216`), which the core calls from
  `sdw_handle_slave_status()` under `cdns->status_update_lock` with the Cadence
  peripheral-status interrupt cleared (`cadence_master.c:1051`, re-enabled only at `:1111`).
- Once `tas2783_sdca_dev_resume()` returns `-ETIMEDOUT` the PM core latches
  `dev->power.runtime_error`; every later `pm_runtime_get*` returns `-EINVAL` (that is the
  `-22`). Live: `power/runtime_status = error` on `:a` and `:9`. **Nothing short of unbind or
  a reboot clears it** — `power/control = on` calls `pm_runtime_forbid()` → `rpm_resume()`,
  which returns the same error.

**Two candidate mechanisms, neither settled:**

(A) *The sibling's firmware download starves the link.* Correlates 6/6 across boots — count the
amps that reached `tas_io_init()` at cold boot (`Failed to read fw binary` is only reachable
from a completed `tas_io_init()`, so it is a clean "this amp attached" marker for the boots
before the symlinks existed):

| boot | patched SDCA | fw symlinks | deferred load | amps that attached |
|---|---|---|---|---|
| -5 … -2 | no | no | no | **all four**, every time |
| -1 | yes | yes | no | `:d`, `:c` only |
| 0 | yes | yes | **yes** | `:d`, `:c` only |

Before the symlinks (created 15:34:42), `request_firmware_nowait()` failed `-ENOENT` and
`tas_io_init()` returned in milliseconds — and all four amps attached on four consecutive
boots. From the moment the blobs resolve, it blocks ~1.2 s pushing ~40 KB in 52 paged writes.
Same shape as thesofproject/linux **#5824** (ASUS ProArt PX13, two TAS2783 on one link):
*"only the second amp fails; the identical download succeeds on a quiescent bus."*

(B) *The core loses the second peripheral during enumeration.* `sdw_handle_slave_status()`
programs **at most one** device number per call and returns immediately
(`if (id_programmed) return 0;`, `bus.c:1928`), relying on the newly-attached device
generating another status change to drive the next round. The only safety-net rescan,
`cdns_check_attached_status_dwork`, is scheduled **once**, 100 ms after `intel_start_bus()`
(`SDW_INTEL_DELAYED_ENUMERATION_MS = 100`, `intel.h:131`; `intel_bus_common.c:69`) — inside
the pre-DSP-boot dead window.

**Why (A) is not proven, and it is important:** on the 16:25 boot the codec driver was
blacklisted and loaded late, so **no download was in flight while the core was enumerating**.
The 6-boot correlation is confounded — boots -5…-2 differ in three variables at once
(no patched SDCA module, no symlinks, no deferral). (A) explains boot -1 cleanly; it does not
explain boot 0.

### The 2026-08-27 04:52 resume — this settles it in favour of (B)

The machine ran an 11.3-hour s2idle (suspend 08-26 17:35:17, resume 08-27 04:52:21). On
resume, link 1 produced this, all inside 5 ms, and **link 2 and 3 produced nothing at all**:

```
04:52:21.982  soundwire sdw-master-0-1: Program device_num 1 failed: -61   (x9, with)
04:52:21.982  soundwire sdw-master-0-1: Assign dev_num failed:-61          (x9)
04:52:21.984  soundwire_intel ...link.1: Msg NACK received, cmd 5 / cmd 0
04:52:21.984  soundwire_intel ...link.1: Msg NACKed for Slave 0
04:52:21.984  soundwire sdw-master-0-1: trf on Slave 0 failed:-5 read addr 50 count 6
04:52:21.985  soundwire sdw-master-0-1: DEVID read fail:-5
04:52:21.987  slave-tas2783 ...:d: resume: initialization timed out
04:52:21.987  soundwire sdw-master-0-1: sdw_show_ping_status: no peripherals attached
04:52:21.987  slave-tas2783 ...:d: PM: dpm_run_callback(): acpi_subsys_resume returns -110
04:52:21.987  slave-tas2783 ...:c: PARITY error detected before INT mask is enabled
```

Three things fall out, and all three point the same way:

1. **`no peripherals attached`** is `sdw_show_ping_status()` reporting `CDNS_MCP_SLAVE_STAT == 0`
   (`bus.c:333-337`). The whole link is empty — not "the second amp is missing", *nothing* is
   there. `Program device_num **1**` is `dev_num_sticky` for `:d`, the amp that worked.
2. **The SOF DSP produced no messages at all across the resume.** No `Booted firmware version`.
   `hda_sdw_int_enable(sdev, true)` only runs from `hda_dsp_post_fw_run()` (`hda.c:454`), after
   the DSP firmware boots — so on resume the SoundWire links come back and enumerate while the
   DSP is still down and SoundWire interrupts are still masked. Every command is
   Command_Ignored. **This is defect 3's window, on the resume path, where the deferred module
   load does nothing** — the deferral delays the *driver*, and enumeration is *core*-level.
3. **All four amps are now UNATTACHED**, `:d` and `:c` included. The state degrades with every
   suspend; a reboot gets `:d`/`:c` back, a suspend loses them again.

And the safety net cannot help in either case: `cdns_check_attached_status_dwork` is scheduled
**once**, 100 ms after `intel_start_bus()` (`intel_bus_common.c:69,163,199`;
`SDW_INTEL_DELAYED_ENUMERATION_MS = 100`, `intel.h:131`) — at boot that is ~200 ms before the
DSP boots, and at resume it fired at 04:52:22.08 into a still-dead bus and silently found
nothing. **There is no second attempt, ever.**

That reframes mechanism (A) as a probable red herring: the firmware download changes *when*
enumeration attempts land relative to the dead window, which is enough to move which amps
survive, without being the cause. **(B) — enumeration runs in a window where the bus is
inert, and is never retried — explains boot -1, boot 0 and the resume with one mechanism.**

**Consequence for the fix:** it must re-arm the rescan until the peripherals actually attach.
The smallest form is a few lines in `cdns_check_attached_status_dwork()`
(`cadence_master.c:1007-1030`): re-`schedule_delayed_work()` while any ACPI-described
peripheral is still UNATTACHED, with a bounded cap. That is one loadable module
(`soundwire-cadence.ko`), it fixes boot *and* resume, and it is upstreamable. `sdca-build/`
already proves an out-of-tree build against this kernel works.

Two module parameters were checked and are **not** the answer, but are worth knowing
(both `0444`, so `modprobe.d` + reboot only):
`snd_sof_intel_hda_generic.sdw_clock_stop_quirks = 8` = `SDW_INTEL_CLK_STOP_BUS_RESET`, the
default (`hda.c:57`); `soundwire_intel.sdw_md_flags = 0`, per-link bitfield
`md_flags >> (link_id * 8)` with `DISABLE_PM_RUNTIME` = BIT(0) (`intel_auxdevice.c:35-42,397`).
`SDW_INTEL_MASTER_DISABLE_CLOCK_STOP` (BIT(1)) is defined but never read in 7.1.9.

---

## 3. Traps — each of these cost time once, do not pay twice

- **`device_number = N/A` does not mean "never enumerated."** `device_number_show()` returns
  the literal string `"N/A"` for **any** slave whose `status == SDW_SLAVE_UNATTACHED`, without
  ever reading `dev_num` (`sysfs_slave.c:237-246`). It tells you nothing about enumeration.
- **System suspend/resume does not recover an amp.** Directly disproven: boot -1 ran a full
  s2idle cycle at 15:40:12 → 15:40:38 and `:a` timed out on resume exactly as before; boot -2
  ran three, all `-110` then `-22`. `intel_resume()` does re-enumerate
  (`sdw_clear_slave_status()` + `sdw_intel_start_bus()`, `intel_auxdevice.c:717-770`), and it
  still does not help.
- **Never unbind/rebind on a live card.** Tearing down `sof-soundwire` breaks the HDA HDMI
  codec, which cannot re-probe at runtime (`HDMI: failed to get afg sub nodes` →
  `hdac_hda_codec_probe: probe failed -22` → `sof_sdw: failed to instantiate card -22`).
  You lose the whole card until reboot. Paid for once already, on boot -1 at 16:09.
- **`-61` is `-ENODATA`** — `SDW_CMD_IGNORED`, the peripheral did not ACK (`bus.c:224-225`).
  Not a missing file.
- **`ping-probe.sh` cannot work on an amp that is already in PM error.** Once
  `power/runtime_status = error` is latched, `pm_runtime_get*` returns `-EINVAL` *without*
  calling the driver, so `tas2783_sdca_dev_resume()` never runs and `sdw_show_ping_status()`
  is never reached. Ask the journal instead — a system resume prints the same line for free.
- **`fw with no files` is a consequence**, not a parsing bug: `tas2783_fw_ready()` breaks its
  per-file loop on the first failed write, leaving `cur_file == 0`. The blob is fine — 40746
  bytes, DDC `HP_Graham_alpha10_251014_Xover_RNS_EQ`, 52 files.
- **Do not upgrade the kernel expecting a fix.** `find_sdca_function()`'s DC-value check is
  byte-identical at 7.1, 7.2 and master, so the OOT SDCA module is still required — and 7.2
  changed `sdca_parse_function()`'s signature, so it needs a rebase before it will build.
  `sdw_program_device_num()`, `sdw_assign_device_num()`, `cdns_update_slave_status_work()` and
  `intel_start_bus()` are all unchanged v7.1 → master.
- **The 4-amp topology stub is a phantom.** `sdca-%damp` is built from `dai_link->num_cpus`,
  which counts SoundWire *links*, not amplifiers. Four amps on two links correctly request
  `sof-sdca-2amp-id2.tplg`, which is real and loads.
- **Do not chase an ACPI asymmetry between the amps.** All four are described identically:
  `SWD1`=`:9`, `SWD2`=`:c`, `SWD3`=`:a`, `SWD4`=`:d`, same `mipi-sdca-*` property sets,
  same `adr` shape.

---

## 4. >>> NEXT STEP <<<

**Light up the boot enumeration window, then fix the retry.** The resume trace above
(§ *The 2026-08-27 04:52 resume*) already gave us the resume half for free. The boot half is
still dark, and it is the one that decides whether the fix is only "re-arm the rescan" or
something more.

```bash
sudo ~/.local/share/omnibook-speaker-fix/sdw-trace.sh arm     # writes /etc/modprobe.d/omnibook-sdw-debug.conf
sudo reboot
~/.local/share/omnibook-speaker-fix/sdw-trace.sh report       # the boot trace
systemctl suspend                                             # then wake it
~/.local/share/omnibook-speaker-fix/sdw-trace.sh report       # the resume trace, now in detail
```

Revert: `sudo ~/.local/share/omnibook-speaker-fix/sdw-trace.sh disarm`. Risk: none, log volume
only. A reboot also restores `:d` and `:c` to Attached, which the last suspend took away.

The six lines that settle it, and how to read them:

| line | source | what it tells you |
|---|---|---|
| `Booted firmware version` | SOF | the instant SoundWire commands start being answered |
| `Slave attached, programming device number` | `bus.c:1914` | the core saw something on device 0 |
| `SDW Slave class_id … unique_id 0x?` | `bus.c:809` | **which** amp answered — whether `0xa`/`0x9` ever appear is the whole question |
| `No more devices to enumerate` | `bus.c:846` | `-ENODATA` on the device-0 DEVID read |
| `Device0 detected after clearing status, iteration N` | `cadence_master.c:1098` | the multi-peripheral rescan loop fired |
| `Peripheral N status: S` | `cadence_master.c:1021` | the 100 ms `attach_dwork` ran, and what it saw |

- Every enumeration attempt lands **before** `Booted firmware version` → mechanism (B) is the
  whole story; go straight to the fix below.
- `unique_id 0xa` never appears even after the DSP boots → `:a` is not answering on device 0
  for a reason of its own, and the retry fix will not be enough.
- `0xa` appears only after `:d`'s download completes → mechanism (A) is live after all; the
  symlink experiment below separates them.

**Then the fix.** Re-arm the rescan instead of running it once: in
`cdns_check_attached_status_dwork()` (`cadence_master.c:1007-1030`), re-`schedule_delayed_work`
while any ACPI-described peripheral is still UNATTACHED, bounded (say 20 tries at 250 ms).
That is one loadable module, `soundwire-cadence.ko`; build it out-of-tree exactly the way
`sdca-build/` builds the SDCA module. It fixes boot **and** resume with one mechanism, and it
is upstreamable — attach it to thesofproject/linux #5877.

**The symlink experiment**, only if the trace points at (A) — one reboot, one variable:

```bash
sudo rm /usr/lib/firmware/updates/8EB4-1-D.bin.zst /usr/lib/firmware/updates/8EB4-2-C.bin.zst
sudo reboot     # revert: sudo ~/.omnibook/bin/omnibook-speaker-firmware link
```

Removing the symlinks for the two amps that currently *succeed* makes their `tas_io_init()`
return in milliseconds again. If `:a` and `:9` then attach, (A) is real; if not, (A) is dead.

### If defect 4 is fixed: the last mile is UCM, and it is a separate defect

`alsa-ucm-conf 1.2.16.1` has **no `tas2783` profile** — `/usr/share/alsa/ucm2/codecs/` has
`rt1318`, `rt1320`, `cs35l56` and friends, no TI. `sof-soundwire.conf:140` includes
`/codecs/${var:SpeakerCodecFile}/init.conf` and `HiFi.conf:16` includes
`/sof-soundwire/${var:SpeakerCodecFile}.conf`. Today `alsaucm -c hw:1 list _devices/HiFi`
returns HDMI1-3, Headset, Headphones, Mic — **no Speaker** — which is why PipeWire shows no
speaker sink even though `hw:1,2` exists.

Model a new file on `rt1320`. **Trap, verified on this machine:** the control is
`Left Spk Switch` (a `SOC_DAPM_PIN_SWITCH`), *not* `Left Spk` —
`amixer -c 1 cget "name='Left Spk'"` returns *Cannot find the given element*, and an
unprefixed failing `cset` aborts the whole `BootSequence`. The real controls are
`Left Spk Switch`, `Right Spk Switch`, `Left Spk2 Switch`, `Right Spk2 Switch`,
`tas2783-1..4 Amp Volume`, `tas2783-1..4 Speaker Volume`,
`Pre Mixer Speaker Playback Volume`, `Post Mixer Speaker Playback Volume`.

---

## 5. Safety and revert

Nothing here touches the boot path. `snd-soc-sdca` is a loadable module (zero hits in
`modules.builtin`), `CONFIG_MODULE_SIG_FORCE` unset, `sig_enforce=N`, lockdown `[none]`,
Secure Boot off. Worst case is no audio until the stock module is restored.

```bash
sudo bash ~/.local/share/omnibook-speaker-fix/apply-speaker-fix.sh --revert
```
restores `snd-soc-sdca.ko.zst.stock` and drops the firmware links. The deferred module load
(defect 3) is separate and is reverted by hand:

```bash
sudo systemctl disable --now omnibook-tas2783-late.service
sudo rm /etc/systemd/system/omnibook-tas2783-late.service \
        /etc/modprobe.d/omnibook-tas2783-defer.conf \
        /usr/bin/omnibook-tas2783-late
sudo systemctl daemon-reload && sudo depmod -a
```

If card 1 is missing after an experiment:
```bash
sudo modprobe -r snd_soc_sof_sdw && sudo modprobe snd_soc_sof_sdw   # often not enough
reboot                                                              # always works
```

---

## 6. Files here

| Path | What |
|---|---|
| `STATE.md` | this file — the persistent record |
| `FIX.md` | the standalone, portable fix for a new device |
| `apply-speaker-fix.sh` | build + install patched SDCA module; `--firmware-only`, `--revert` |
| `probe-fw-download.sh` | live unbind/bind retry experiment (its "verdict" line is buggy — read the `fid=` lines). **Do not re-run on a live card — see Traps.** |
| `ping-probe.sh` | read-only PING-bitmap probe. **Defeated by the PM-error latch — see Traps.** |
| `sdw-trace.sh` | `arm`/`disarm` dyndbg for the SoundWire stack, `report` the enumeration trace, `state` the whole stack. The working tool. |
| `STATE.md.bak-session3` | this file as it stood before session 4 |
| `sdca-build/` | v7.1.9 `sound/soc/sdca/` with the patched `sdca_functions.c` + a working Kbuild Makefile. The proven OOT recipe on this machine. |
| `sof-topology-fix/` | upstream `[1-3]`→`[1-4]` gate fix and the generated `"4"` case for `sdw-amp-generic.conf` — for reporting, not needed here |
| `sof-sdca-4amp-id2.tplg` | a correctly built 4-amp topology (15738 bytes) — for reporting upstream, not needed here |

Repo side (branch `dev` of `~/.omnibook`, commits `b9c487b`, `3e0cdd3`):
`bin/omnibook-speaker-firmware` and README › *Laptop speakers*. Only the firmware-symlink
half belongs in the repo — the kernel modules are machine- and kernel-version-specific and
must not ship to other users.

## 7. Upstream

Trackers, all open, none answered, **nothing filed by us**:
thesofproject/linux **#5877** and **#5802** (this exact board), **#5816** and **#5760**
(sibling HP chassis), Launchpad **#2143870**.

**#5824** (ASUS ProArt PX13, AMD manager, two TAS2783 on one link) is the closest match to
defect 4 and nobody has connected it to the HP reports: *only the second amp fails, the
first one's download always completes, and the identical download succeeds on a quiescent
bus.* Different manager, same symptom — the strongest independent corroboration there is.
#5760 was resolved by a BIOS emitting `mipi-sdca-control-dc-value`, which would retire the
OOT SDCA module entirely — worth re-checking HP for a BIOS newer than Insyde F.06.

Relevant commits after v7.1 (none applied here):
`b627da43035744` drop stale regcache on uninitialized re-attach ·
`0d6b2d6f93a671` propagate regcache_sync() errors ·
`e26bb459d0f3da` firmware names for linux-firmware 20260519 (defect 2) ·
`ea9ff3b7bcfbcd` add back `sdw_show_ping_status()` ·
`ca1063ae03dcbf` + `ac6d4f298160be` new SoundWire enumeration helper.

Two people report sound from this patch class on sibling HP boards
(thesofproject/linux#5760, Launchpad #2143870); neither filed upstream.
