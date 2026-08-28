# The four defects

Each one alone is enough to kill the speakers. They stack, and clearing one only reveals
the next. Line numbers are from Linux 7.1.9 unless stated.

---

## Defect 1 — the BIOS hides the amplifier's function type (ACPI/SDCA). **Fixed.**

The OEM DSDT omits `mipi-sdca-control-dc-value` from each amplifier's
`mipi-sdca-control-0x5-subproperties`. `find_sdca_function()` therefore cannot read the
SDCA Function type and drops every amplifier:

```
acpi device:NN: function type only supported as DisCo constant
```

No amp SDCA function → no amp DAI link → no `Speaker` PCM. The card lands on profile `off`
with a null sink and `alsa.components` reporting `cfg-amp:0`.

That lookup is **byte-identical in 7.1, 7.2, mainline and linux-next**, and upstream has
deliberately declined to accept the non-DC form. It needs a BIOS fix — or the local patch
in `kernel/sdca/`, which assumes `SMART_AMP` when the DC value is unreadable **and** the
peripheral is TI (`mfg_id 0x0102`, `part_id 0x0000`), so no other vendor's genuinely
broken description is silently papered over.

`omnibook-speaker-fix sdca` fetches `sound/soc/sdca/` for the running kernel from
git.kernel.org, applies that patch, builds an out-of-tree `snd-soc-sdca.ko`, and installs
it beside the stock module (kept as `snd-soc-sdca.ko.zst.stock`).

**Proof it is working**, once per boot, once per amplifier:

```
no DisCo constant for function type, assuming SmartAmp   x4
Found Smart Amp function at index 0                      x4
```

plus `cfg-amp:4` in `alsa.components` and a `Speaker` PCM at device 2.

> `Found Smart Amp function at index 0` does **not** mean the amp is on the bus. It is
> printed from the codec probe for `UNATTACHED` peripherals too — see defect 4.

Resolved upstream on a sibling chassis (thesofproject/linux #5760) by a BIOS that emits
`mipi-sdca-control-dc-value`. Worth re-checking HP for firmware newer than Insyde F.06.

---

## Defect 2 — the kernel asks for a firmware filename nobody ships. **Fixed.**

Linux ≤ 7.1's `tas2783-sdw` builds the name `%04X-%1X-%1X.bin` from the audio controller's
PCI subsystem id, the SoundWire link and the peripheral's unique id — `8EB4-1-A.bin`.
linux-firmware 20260810 ships it as `8EB4-1-0xA.bin.zst`. Every load returns `-ENOENT`, the
amp DSP is never programmed, and `tas_sdw_hw_params()` then refuses playback with `-EINVAL`.

```
Direct firmware load for 8EB4-1-A.bin failed with error -2
```

Fixed upstream in 7.2 by `e26bb459d0f3` (*"ASoC: tas2783: Update loaded firmware names to
linux-firmware 20260519"*), which asks for the `0x` name and falls back to the old one.

`omnibook-speaker-fix firmware` adds symlinks under `/usr/lib/firmware/updates/` — the
firmware loader's own override directory, ahead of `/usr/lib/firmware` in `fw_path[]` and
owned by no package. It only ever **adds links**, never touches a shipped blob, and is a
no-op once the plain name resolves, so it stands down by itself on 7.2+.

---

## Defect 3 — *"the firmware download races the audio DSP boot"*. **Does not exist as diagnosed.**

This was the working theory for two sessions. The premise is false on Panther Lake, twice
over:

1. **`hda_sdw_int_enable()` is a no-op here.** It does
   `chip = get_chip_info(...); if (chip && chip->enable_sdw_irq) chip->enable_sdw_irq(...)`
   (`sound/soc/sof/intel/hda-dsp.c:1252-1263`) — and `ptl_chip_info` (`intel/ptl.c:104-129`)
   **has no `.enable_sdw_irq` member at all**.
2. **`hda_dsp_post_fw_run()` is dead code here.** `sof_lnl_set_ops()` installs
   `dsp_ops->post_fw_run = lnl_dsp_post_fw_run` (`intel/lnl.c:118`), and that function
   (`lnl.c:86-101`) only sets `imrboot_supported`.

The SoundWire interrupt is actually enabled at *link power-up*, by
`hdac_bus_eml_enable_interrupt_unlocked(..., AZX_REG_ML_LEPTR_ID_SDW, true)`
(`drivers/soundwire/intel_ace2x.c:568-569`) — **267 ms before the DSP boots**. Every
enumeration read and write in that window is ACKed, and with dyndbg armed all four
amplifiers enumerate perfectly and are confirmed `ATTACHED` before the DSP boots.

The two log lines that seemed to prove otherwise are both traps:

- **`-61` is `-ENODATA`**, which the SoundWire core returns for `SDW_CMD_IGNORED` — the
  peripheral did not ACK (`drivers/soundwire/bus.c:224-225`). It is not a missing file, and
  it is equally well explained by the amplifier *having just left the bus*.
- **`fw with no files` is a consequence, not a parsing failure.** `tas2783_fw_ready()`
  breaks out of its per-file loop on the first failed write, leaving `cur_file == 0`. The
  blob is fine — on this board it is 40746 bytes and parses to 52 files.

**The workaround is still installed and is deliberately left alone.** The deferral
(`omnibook-tas2783-defer.conf` + `omnibook-tas2783-late.service`) does not have a valid
rationale any more, but no evidence shows it either prevents or causes the loss: one boot
had it and lost all four amps, one lacked it and also lost all four. Removing it is an
attended-reboot experiment nobody has run. `omnibook-speaker-fix undefer` removes it.

---

## Defect 4 — the amplifiers leave the bus and never return. **Worked around, not fixed.**

This is the real one, and it is the reason the fix delivers mono rather than stereo.

The amplifiers enumerate cleanly, take device numbers, are confirmed `ATTACHED` by the
100 ms Cadence attach rescan — and then, ~8 seconds before the ASoC card is built, one or
more of them **report Not Present and never re-attach**. There is no rescan left to notice:
`cdns_check_attached_status_dwork()` is the only rescan of the PING status, and
`intel_start_bus*()` schedules it exactly once.

**Where the detach happens, measured.** Inside the FW_READY wait, **66 ms after the
code-loader DMA has stopped** and **2.98 ± 0.61 ms before `firmware boot complete`**, across
three boots and two different DSP-boot durations. The code loader is exonerated; the DSP
firmware itself is not, and the remaining discriminator (a DSPless boot with
`snd_sof.sof_debug=0x8000`) has not been run.

**Why one dead amp kills all of them.** ACPI still describes the dead amplifiers, so they
still become codec components of the aggregated `SDWn-Playback-SmartAmp` BE.
`snd_soc_pcm_component_pm_runtime_get()` walks every component and tolerates only
`-EACCES`; a dead amp's `runtime_error` is latched at `-ETIMEDOUT` by
`tas2783_sdca_dev_resume()`, so `pm_runtime_get_sync()` returns `-EINVAL` and the **whole**
`Speaker` PCM fails to open — including the amps that are alive with firmware loaded.

**The workaround** (`kernel/sdw-utils/`) drops SmartAmp endpoints whose peripheral is off
the bus, in `asoc_sdw_parse_sdw_endpoints()`, so the BE is built from the survivors alone.
Details that make it safe:

- It runs ~8 s *after* the detach (machine select runs ~160 ms *before* it, which is why the
  filter cannot live there).
- The predicate is deliberately **not** `dev->power.runtime_error` — that is latched ~5.3 s
  *after* this code runs, so it would filter nothing.
- Nor is it a bare status read: healthy peripherals read `UNATTACHED` transiently on every
  link resume (observed 2.6–3.0 ms wide). So it reads the status, and if it is not
  `ATTACHED` waits up to 250 ms on `initialization_complete` — which the core re-arms on
  detach and completes only on a real re-attach — then reads again.
- Fail-safe: anything unexpected **keeps** the endpoint, so a lookup failure can never
  silently empty the dailink.
- Confined to `SOC_SDW_DAI_TYPE_AMP` on purpose: the RT712 jack/mic path works and must not
  be touched.
- `filter_unattached_amps=N` disables it without reverting the module.

### Can the dead amplifiers be recovered? No — not locally.

- **Recovery is closed.** A *completed* s2idle exercised the strongest reset the kernel has
  — controller to D3, all links down, Cadence soft reset, bus `HW_RST`, full device-0
  re-enumeration, no DSP running. The survivors were hard-reset and re-downloaded firmware;
  the dead ones did not answer. **Suspend/resume is not a workaround.**
- **No BIOS to flash.** Insyde F.06 is both installed and the newest HP ever published for
  board `8EB4`, and nothing in F.02→F.06 touches audio or ACPI.
- **No ACPI asymmetry to chase.** All four amps are described identically, and none has an
  ACPI power resource or `_PSx`.
- **The clock is not the lever.** The failures are at 4.8 MHz, not 9.6 — 768 of 773
  `curr_freq` samples read 4,800,000.
- **Even fixed, stereo needs more.** The per-amp channel split is unmerged upstream, and it
  would not help today anyway: both survivors are physically on the left.

### The finding worth filing upstream

**The dying amplifiers are marginal, not absent.** Instrumented across boots, one of them
returned its correct DEVID **31 times**, took a device number **24 times**, then failed its
first register write **every time** with parity errors — and seven DEVID reads came back
bit-corrupted, two of which manufactured phantom devices. **Detection is not the failure;
register I/O is.** Nobody upstream has posted this. See [upstream.md](upstream.md).
