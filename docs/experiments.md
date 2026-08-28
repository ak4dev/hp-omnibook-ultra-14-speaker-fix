# The two module swaps that are NOT part of `install`

Both are built and reviewed. **Both are contraindicated on the current evidence, and
neither is installed on the reference machine.** They are kept because the analysis is worth
having and because one of them is worth sending upstream.

Each can cost the **whole sound card** until it is reverted and the machine rebooted — and on
a box whose root filesystem is unlocked by a hardware key, a reboot needs a human at the
console. Read [traps.md](traps.md) first.

---

## `cadence` — re-arm the attach rescan

`kernel/cadence/0001-sdw-cadence-rearm-attach-rescan.patch`

`cdns_check_attached_status_dwork()` is the only rescan of the PING status, and
`intel_start_bus*()` schedules it exactly once, 100 ms after the bus starts. A peripheral
that falls off after that is never looked for again. The patch adds two arming points — one
where the loss is observed, one in the dwork itself — bounded to 20 tries at 250 ms, ending
as soon as no peripheral holding a `dev_num_sticky` is `UNATTACHED`.

The new struct field goes in an existing hole, so `sizeof(struct sdw_cdns)` and every offset
in the `struct sdw_intel` that embeds it are unchanged and the stock `soundwire-intel.ko`
does not need rebuilding. **Do not move it.**

**Why it is not installed.** Its mechanism already ran three more times on an instrumented
boot, for free, and returned nothing:

- `Peripheral 2 status` appears exactly twice in the whole boot and never again.
- The post-detach rescans print `Peripheral 1 status: 1` alone — and the print is gated on a
  non-zero status (`cadence_master.c:1020-1021`), so the **absent line is the reading**.
- Four full device-0 sweeps found only the two survivors.
- `sdw_show_ping_status` reports `0x4` on both masters.

And it has a cost: `cdns_peripheral_missing()` keys on `dev_num_sticky`, which is never
cleared here, so the retry would run its full 20 × 250 ms on **every** bus start — and can
drive `tas_io_init()`'s software reset plus its 3-second blocking download onto the two
*surviving* amplifiers.

**Keep it for upstream**, with that corrected rationale. See [upstream.md](upstream.md).

---

## `sof-order` — start the SoundWire links from `post_fw_run()`

`kernel/sof-sdw-order/0001-sof-start-sdw-links-after-fw-boot.patch`

The idea: on ACE 2.0+ `hda_dsp_probe()` starts the SoundWire links ~265 ms before the DSP
firmware boots (`hda.c`, gated on `hw_ip_version >= SOF_INTEL_ACE_2_0`); upstream made that
change as an optimisation. Moving the startup back into `post_fw_run()` would enumerate the
peripherals after the DSP is up.

**It passes the old evidence and fails on substance — five objections, none addressed:**

1. `snd_sof_dsp_post_fw_run()` is `loader.c:171`, so it relocates link start to ~5.7 ms
   **after** the instant the amps died, still inside the ~103 ms of post-boot work. It lands
   on the edge of the window, not clear of it.
2. Its premise is falsified: a second DSP firmware boot later in the same session detached
   nothing.
3. Its own header comment's evidence is now false ("every amplifier reports NPRESENT",
   "none ever re-attaches").
4. **It destroys the DSPless control arm.** With `snd_sof.sof_debug=0x8000` the core skips
   `snd_sof_run_firmware()` entirely (`core.c:469-471`), so `post_fw_run` never runs and no
   SoundWire link is started at all — silently removing the one experiment that would
   exonerate or convict the DSP.
5. It makes `hda_sdw_startup()`'s `if (pdata->machine && !mach_params.link_mask) return 0;`
   (`hda.c:241-242`) live for the first time. At the current call site `pdata->machine` is
   NULL (`core.c:375` precedes `core.c:382`), so a zero mask would silently produce a card
   with **no links**.

**Blast radius.** A non-zero return from `snd_sof_run_firmware()` aborts the SOF probe before
the card is registered, taking the headset jack, HDMI 1–3, the deepbuffer PCM and the
microphones with it — everything except a USB device.

If it is ever rebuilt: add a dspless carve-out, log `mach_params.link_mask` before calling
`hda_sdw_startup()`, and rewrite the header comment. `omnibook-speaker-fix sof-order` is
deliberately not wired up — this repo does not vendor a full `sound/soc/sof/intel` tree, so
the patch has to be built by hand.

---

## The experiment that would actually settle defect 4

**A DSPless boot.** `options snd_sof sof_debug=0x8000`. The links still start —
`hda.c:911-913` gates `hda_sdw_startup()` only on `hw_ip_version >= SOF_INTEL_ACE_2_0` —
while `core.c:469-471` skips `snd_sof_run_firmware()` entirely. If the amps still detach, the
DSP is exonerated and the cause is elsewhere.

Cost: two attended reboots and no DSP audio in between. Not yet run.

## Readings still worth taking with root available

```bash
# Does the DSDT give the four amps a shared power resource, a GpioIo in _CRS,
# a PowerResource/_ON/_OFF, or any asymmetry between the dying and surviving pairs?
sudo cp /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT* ./archive/evidence/acpi/

sudo cat /sys/kernel/debug/soundwire/master-0-*/intel-sdw/intel-registers
```

The DSDT read has never been taken; the "do not chase an ACPI asymmetry" note in
[traps.md](traps.md) is inferred from sysfs and has never been checked against the tables. If
it shows one, a local lever exists after all.
