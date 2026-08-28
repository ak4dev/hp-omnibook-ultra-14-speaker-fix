# Laptop speakers (TAS2783 SoundWire) — persistent state

**Last updated: 2026-08-27, session 6.** This file is the authoritative, reboot-surviving
record. It lives outside `/tmp` on purpose (`/tmp` is tmpfs here). Read it first.
Session 4's version is kept as `STATE.md.bak-session4` (**large parts wrong** — see § 2.0);
session 5's as `STATE.md.bak-session5`. Session 6 rewrote § 5 entirely and added § 2.5.

Companion documents in this directory:
- `standalone/README.md` — the portable fix for a *new* device.
- `sdw-trace.sh` — `arm`/`disarm` dyndbg for the SoundWire stack, `report` the enumeration
  trace, `state` the whole stack. The working tool. **Currently ARMED.**
- `ucm-overlay` — the ALSA UCM last mile, root-free. See § 6.
- `cadence-build/` — an out-of-tree `soundwire-cadence.ko` with the rescan re-arm patch.
- `sdca-build/` — the out-of-tree `snd-soc-sdca.ko` that gets past the BIOS defect.

---

## 0. Where this stands in one paragraph

Defects 1 and 2 are fixed and stay fixed; defect 3 does not exist as diagnosed. **Defect 4 has
changed shape.** On the 2026-08-27 12:00 boot only **two** of four amps were lost — device 2 on
each link — and the two survivors completed full firmware downloads and are still attached. The
detach is now bracketed by live hardware register reads to an 85 ms interval lying **entirely
inside the DSP firmware boot**, 3.2 ms before `firmware boot complete` (§ 2.5). That is the
measurement § 5 asked for; it rules a great deal out but does not name a mechanism, and a second
DSP firmware boot later in the same boot detached nothing, which falsifies the simple version of
the DSP story. **The blocker is no longer "no amps".** A `Speaker` PCM exists at `hw:1,2` and
fails to open with `-22` because a dead amp is still a codec of the same aggregated BE and its
`runtime_error` is latched — four gates deep, all traced to source in § 2.5. Nothing root-free
clears it; no mixer, UCM or DAPM setting routes around it; and no upstream fix exists. **Both
staged kernel experiments are now contraindicated** (§ 5.1). The next step is RANK 2 in § 5:
one attended sitting, `hda-loader.c` instrumentation, to place the detach inside the code-loader
DMA or the FW_READY wait — and RANK 3, an endpoint filter in `soc_sdw_utils.c`, is the only
route to actual sound from the hardware behaviour observed.

## 1. The machine, and how to tell whether another one is affected

HP OmniBook Ultra Laptop 14-kd0xxx, board / PCI-subsystem id **`8EB4`**, Intel Panther Lake
(SOF **ACE 3.0**, `ptl_chip_info`). Four TI TAS2783 SoundWire amplifiers — link 1 uids
`a`,`d`; link 2 uids `9`,`c` — plus an RT712 headset codec on link 3. Arch Linux, kernel
**7.1.9-arch1-2**, linux-firmware 20260810-2, sof-firmware 2025.12.2-1, alsa-ucm-conf
1.2.16.1, BIOS Insyde F.06 (2026-06-25).

```bash
cat /sys/class/dmi/id/product_name /sys/class/dmi/id/board_name
ls /sys/bus/soundwire/devices/            # sdw:0:<link>:0102:0000:01:<uid> == TAS2783
journalctl -k -b 0 | grep -iE "tas2783|DisCo constant|SmartAmp|FW download"
aplay -l | grep -i speaker
```

Affected if: TAS2783 peripherals present, **no** `Speaker` PCM, and the log carries
`function type only supported as DisCo constant`.

---

## 2. The defects

### 2.0 What session 5 overturned — read this before trusting anything older

Three of session 4's load-bearing claims are **false**, each disproven from the shipped
kernel source or from the dyndbg trace of the 05:09 boot:

1. **"SoundWire interrupts are only enabled in `hda_dsp_post_fw_run()`, after the DSP
   firmware boots."** False on this platform, twice over.
   `hda_sdw_int_enable()` (`sound/soc/sof/intel/hda-dsp.c:1252-1263`) does
   `chip = get_chip_info(...); if (chip && chip->enable_sdw_irq) chip->enable_sdw_irq(...)`
   — and **`ptl_chip_info` (`intel/ptl.c:104-129`) has no `.enable_sdw_irq` member at
   all**, so the call is a no-op. And `hda_dsp_post_fw_run()` itself is dead code here:
   `sof_lnl_set_ops()` installs `dsp_ops->post_fw_run = lnl_dsp_post_fw_run`
   (`intel/lnl.c:118`), and `lnl_dsp_post_fw_run` (`lnl.c:86-101`) only sets
   `imrboot_supported`. The SoundWire interrupt is actually enabled at *link power-up*, by
   `hdac_bus_eml_enable_interrupt_unlocked(..., AZX_REG_ML_LEPTR_ID_SDW, true)`
   (`drivers/soundwire/intel_ace2x.c:568-569`), 267 ms **before** the DSP boots. That is
   why every enumeration read and write at 46.038-46.048 was ACKed.
2. **"The core never sees the second amplifier on each link."** False. With dyndbg armed,
   **all four amps enumerated perfectly**, got device numbers, and the 100 ms Cadence
   attach rescan confirmed all four ATTACHED — all of it before the DSP booted. See § 2.4.
3. **"`-61` proves the bus was dead in the pre-DSP-boot window."** `-61` is `-ENODATA`
   (`SDW_CMD_IGNORED`) and is equally well explained by the *amplifier having left the
   bus mid-download*. On the 05:09 boot, writes in that same window succeeded.

Consequence: **defect 3 as written does not exist.** What follows about its workaround is
narrower than it looks: the *rationale* on the file is false, and no evidence shows the
deferral either prevents or causes the loss (boot 0 had it and lost all four; boot -2
lacked it and also lost all four). Leave it in place, and correct the comment when root is
next available.

### Defect 1 — ACPI/SDCA function type. **SOLVED (out-of-tree module). Keep.**
The OEM DSDT omits `mipi-sdca-control-dc-value` from each amplifier's
`mipi-sdca-control-0x5-subproperties`, so `find_sdca_function()` rejects all four amps
(`acpi device:NN: function type only supported as DisCo constant`). Byte-identical in 7.1,
7.2, mainline and linux-next; upstream has declined the non-DC form on purpose.

Fixed by a locally built `snd-soc-sdca.ko`: v7.1.9 `sound/soc/sdca/` verbatim except
`sdca_functions.c`, which assumes `SMART_AMP` for a TI peripheral (`mfg_id 0x0102`,
`part_id 0x0000`) whose DC value is unreadable.

**Status: INSTALLED and working.** `/lib/modules/7.1.9-arch1-2/kernel/sound/soc/sdca/`
holds `snd-soc-sdca.ko.zst` (patched) with the stock kept as `snd-soc-sdca.ko.zst.stock`.
Proof every boot: `no DisCo constant for function type, assuming SmartAmp` x4,
`Found Smart Amp function at index 0` x4, `cfg-amp:4`, and a `Speaker` PCM at `hw:1,2`.
Unsigned, so it taints; harmless (`CONFIG_MODULE_SIG_FORCE` unset, lockdown `[none]`,
Secure Boot off).

### Defect 2 — firmware file naming. **SOLVED (symlinks). Keep, but see the caveat.**
Linux 7.1 builds `%04X-%1X-%1X.bin` from the PCI subsystem id, link and uid
(`8EB4-1-A.bin`); linux-firmware 20260810 ships `8EB4-1-0xA.bin.zst`. Four symlinks in
`/usr/lib/firmware/updates/`, managed by `~/.omnibook/bin/omnibook-speaker-firmware`
(`status`/`link`/`unlink`), which derives every name at runtime from
`/sys/bus/soundwire/devices`. Only needed on kernels < 7.2 — mainline commit
`e26bb459d0f3` asks for the `0x` name and falls back, and the driver grew a
`fw_use_fallback` flag for it.

**A caveat session 5 raised and then retired:** it looked as though the amps survived on
every boot where the blobs did not resolve, which would have made the symlinks suspect.
They did not — see § 3. In boots -5, -4 and -3 `:a` is already dead at the first resume,
exactly as in every later boot; those boots were simply never observed after the window in
which amps die. The symlinks are not implicated.

### Defect 3 — "the firmware download races the audio bring-up". **AS DIAGNOSED, DOES NOT EXIST.**
See § 2.0 for why the premise is false on Panther Lake. The workaround
(`/etc/modprobe.d/omnibook-tas2783-defer.conf` + `omnibook-tas2783-late.service` +
`/usr/bin/omnibook-tas2783-late`) is still installed and enabled, and **should stay that
way for now**.

Session 4 recorded it as "WORKING" on the evidence of *zero* `FW download failed` lines and
`cfg-amp:4`. Both readings were wrong: there were zero download failures because there were
zero **downloads** — all four amps were gone by the time the deferred module loaded — and
`cfg-amp:4` comes from the ACPI/SDCA description (defect 1's fix), not from a working
amplifier.

That makes the deferral *unproven*, not *harmful*. Boot 0 had it and lost all four amps;
boot -2 had no deferral and also lost all four. Removing it is a legitimate experiment
(`omnibook-speaker-fix undefer`) but it is not a fix, and it should be run only after the
measurement in § 5, one variable at a time.

### Defect 4 — the amplifiers leave the bus and never return. **THE WALL.**

The 2026-08-27 05:09 boot, dyndbg armed on `soundwire_bus`, `soundwire_cadence`,
`soundwire_intel` and `snd_soc_tas2783_sdw`. Timestamps are wall-clock within 05:09:

| t | event |
|---|---|
| 46.0388 | link 1 `Slave status change: 0x2` — device 0 attached |
| 46.0390 | `Slave attached, programming device number`; DEVID reads for uid `0xd` and `0xa` |
| 46.0405 | `Slave status change: 0x221` — dev0 NPRESENT, **dev1 + dev2 ATTACHED** |
| 46.0407-46.0418 | `:d` = Slave 1 and `:a` = Slave 2 both get enumeration **and** initialization completion; `Configured bus base 1, scale 2, mclk 19200000, curr_freq 9600000` for each |
| 46.0420-46.0451 | link 2 does the identical thing: `:c` = Slave 1, `:9` = Slave 2 |
| 46.0472-46.0484 | link 3: RT712 = Slave 6, same |
| 46.1438-46.1441 | the 100 ms Cadence attach rescan: `Peripheral 1 status: 1`, `Peripheral 2 status: 1` on **both** amp links — all four confirmed ATTACHED |
| **46.2128** | link 1 `Slave status change: **0x110**` — dev1 **and** dev2 NPRESENT |
| 46.2144 | link 2, the same, 1.6 ms later |
| 46.3058 | `Booted firmware version: 2.14.1.1` — **93 ms after the amps died** |
| 47.3928-47.3946 | the deferred codec module finally loads; all four probe and print `Peripheral status = unattached` |
| 47.8558+ | `error playback without fw download`, `ASoC error (-22)` |

After 47.4 there is **no further `Slave status change` on link 1 or link 2 for the entire
boot**. Link 3 keeps working.

**Established, with source:**

- The nibble decode is confirmed (`cadence_master.c:112-119`): `slave_intstat` is 4 bits
  per peripheral, `NPRESENT=BIT(0)`, `ATTACHED=BIT(1)`, `ALERT=BIT(2)`, `RESERVED=BIT(3)`,
  assembled `((u64)slave1 << 32) | slave0` at `:1064`. The separate `Peripheral N status:
  %d` line is a *different* 2-bit-per-peripheral encoding read from `CDNS_MCP_SLAVE_STAT`
  (`:1016-1023`), where `1 == SDW_SLAVE_ATTACHED`.
- **Nothing in software did it.** `Slave status change` is only printed by
  `cdns_update_slave_status_work()`, which runs only from `schedule_work(&cdns->work)` in
  `sdw_cdns_irq()` — a real hardware interrupt. The software force-unattach path,
  `sdw_clear_slave_status()` (`bus.c:2023-2050`), does **not** print `state check1` — so
  this was not a driver-initiated invalidation. The four amps stopped answering PING.
- **No link was reset, power-cycled or suspended.** `intel_link_power_up()`'s
  unconditional `clock source %d LVSCTL %#x` (`intel_ace2x.c:468`) appears exactly three
  times in the whole boot, once per link. On the 05:09 boot links 1 and 2 read `runtime_status=active`
  with `runtime_suspended_time=0`. **That datum is spent on the 12:00 boot**:
  `soundwire_intel.link.1` now reads `runtime_suspended_time=902`, `link.2` reads `44`, and
  both power-cycled and fully re-enumerated three times after the detach
  (`clock source 0 LVSCTL 0x0` at 43.241872/43.244174, 45.200946/45.202722,
  49.167028/49.166593). The no-PM-transition argument applies to the 05:09 window only. The
  link autosuspend delay is 3000 ms (`intel_auxdevice.c:26,428`), far outside the window.
  Positive control: link 3 *did* clock-stop, at 05:09:53.37.
- **`sdw_clock_stop_quirks=8` (`SDW_INTEL_CLK_STOP_BUS_RESET`) is read only on PM
  transitions**, and none occurred.
- **The window is empty.** Between the last core write at 46.1004 and the detach at
  46.2128 there is no SoundWire activity at all — only journald, Bluetooth and zswap.
- **What reaches a driverless ATTACHED slave** is: `SCP_DEVNUMBER` (`bus.c:782`), then one
  `sdw_initialize_slave()` (`bus.c:1417`) which writes `SCP_BUS_CLOCK_BASE` and
  `SCP_BUSCLOCK_SCALE_B0/B1` (reached because `slave->id.class_id`=0x01 passes the gate at
  `:1388`, using **bus** properties not `slave->prop`), optionally clears initial
  clash/parity, then `sdw_update_no_pm(SDW_SCP_INTMASK1, 0, 0)` — a zero-mask RMW — and
  returns because `prop.dp0_prop` is NULL. TAS2783 has **no `.read_prop`** in
  `sdw_slave_ops` (`tas2783-sdw.c:1261-1264`) and never sets `scp_int1_mask`, so that last
  write is the same no-op with or without the driver. **There is no keep-alive, no
  deadline and no timer anywhere in the core.**

**The one measurement that survived adversarial review.** The detach is *not* well
predicted by time-since-enumeration; it is much better predicted by time-before the DSP
firmware is up. On boot 0 the two links reported NPRESENT at 46.212825 and 46.214455 and
`Booted firmware version` came at 46.305815 — **92.99 ms and 91.36 ms**.

**But be precise about how thin that is.** Those two numbers are *one* hardware event seen
on two links 1.6 ms apart, so this is **N = 1, not N = 2 and not N = 4**. Boot −2 looks
like a second measurement (`FW download failed: -61` at 91.98/91.37 ms before `Booted`) and
is not one: boot −2 had no SoundWire dynamic debug in its failure window, so there is no
NPRESENT report there at all. What is timestamped is the driver's *first ignored write*,
whose instant is set by when `request_firmware_nowait()` completed — an **upper bound** on
the detach, not the detach. Boot −1 had **no dynamic debug at all** (0 lines for every
debug string, against 60 624 in boot −2), so every attach/detach timing anyone reads off
boot −1 is absence of evidence.

**Two hypotheses that were argued for and are NOT established:**

- *"A TAS2783 removes itself ~150–170 ms after its last register write."* Built on a
  dose-response across boots −6…0. The dose-response is an **artefact**: for boots −6…−3
  the only evidence of an amp being alive is the firmware request, which happens *before*
  the window in which amps die. Checked directly — in boots −5, −4 and −3 `:a` is already
  dead at the first resume (`resume: initialization timed out`,
  `intel_resume_child_device: pm_runtime_resume failed: -110`), exactly like every later
  boot. So those boots did **not** keep four amps; they were simply measured too early.
- *"The deferral is the cause / the deferral is essential."* Neither. Boot 0 **had** the
  deferral and lost all four. Boot −2 lacked it and also lost all four (its 14 157
  `state check1` events are a bound driver retrying against dead peripherals — and boot −2
  is confounded by dyndbg being on). What *is* established is only that the deferral's
  written rationale is false (§ 2.0). Do not replace one unsupported rationale with another.

**Alternatives still open**, none excluded: the loss is timed by the host's post-boot
library load rather than the DSP itself (the `Loaded firmware library` #2 marker sits only
5–9 ms from the detach, and #2 → `Booted` varies by 7 ms across boots, so the "1.6 ms
tightness" depends on choosing `Booted` as the reference); the HDA code-loader DMA on the
extended multi-link the SoundWire links sit under; a fixed ~175 ms delay from link
power-up; concurrent platform firmware activity in the same window (Bluetooth was pulling a
446 ms controller download, plus the ISH loader and iwlwifi, in *both* boots); or an
amp/board-side event with no kernel trigger at all, in which case both alignments are
coincidence. The strongest single counter-argument to the DSP story remains unanswered:
**link 3's RT712 sits on the same shim and is untouched at that instant.**

**The measurement has been taken and did not settle it** (see § 2.5). What it did settle is
where *not* to look, and it added a new and sharper lead: selectivity.

**Formerly: the measurement that would settle it has never been taken.**
`snd_sof_dsp_post_fw_run()` runs between `firmware boot complete` and
`Booted firmware version` (`sound/soc/sof/loader.c`: the boot wait, then
`dev_dbg("firmware boot complete")`, then `snd_sof_dsp_post_fw_run()`, then
`ipc->ops->post_fw_boot` which is what prints `Booted firmware version`). Both of those
`dev_dbg` lines were off — `snd_sof` was never instrumented. `omnibook-speaker-fix trace`
now adds `options snd_sof dyndbg="file loader.c +p"` for exactly this. **One traced boot
with that line puts the detach on one side or the other of the DSP boot.**

**What is certain regardless of mechanism:** once an amp goes NPRESENT there is no recovery
path. `cdns_check_attached_status_dwork()` — the only rescan of the PING status — is
scheduled **exactly once** per bus start, 100 ms after `intel_start_bus()`
(`SDW_INTEL_DELAYED_ENUMERATION_MS`, `intel.h:131`; `intel_bus_common.c:69,163,199`). On
this boot it ran at 46.144, 69 ms *before* the loss, saw everything healthy, and was never
scheduled again.

---

### 2.5 The 2026-08-27 12:00 boot — the measurement, and a new blocker

**Session 6.** Full dyndbg on the SoundWire stack *plus* `snd_sof dyndbg="file loader.c +p"`,
which is what finally lit the DSP boot boundary.

```
40.852002  link.1: clock source 0 LVSCTL 0x0        (intel_link_power_up, intel_ace2x.c:468)
40.861837  booting DSP firmware                     (loader.c:138)
40.933283  link.1: Peripheral 1 status: 1           <- LIVE CDNS_MCP_SLAVE_STAT read,
40.933460  link.1: Peripheral 2 status: 1              all four amps ATTACHED, +71.6 ms
41.018597  link.1: Slave status change: 0x100       <- dev2 NPRESENT ONLY  (+156.760 ms)
41.019338  link.2: Slave status change: 0x100                              (+157.501 ms)
41.021811  firmware boot complete                   (loader.c:167)         (-3.214 ms)
41.022595  Loaded firmware library: ADSPFW #2                              (+0.784 ms)
41.124604  Booted firmware version: 2.14.1.1                               (+102.793 ms)
```

**The detach is bracketed on both sides by hardware register reads** — the lower bound is
`cdns_check_attached_status_dwork()`'s live `cdns_readl(CDNS_MCP_SLAVE_STAT)`
(`cadence_master.c:1007-1023`). The hardware event lies in [40.9335, 41.0186], an 85 ms
interval **entirely inside `snd_sof_run_firmware()`**. It cannot be localised further: the host
is asleep in `wait_event_timeout()` (`loader.c:154`) for most of it, and `hda-loader.c` dyndbg
was not armed, so the code-loader DMA and the FW_READY wait are indistinguishable here.

**Two facts stop this being a verdict on the DSP boot.**
1. A **second** complete DSP firmware boot ran at 54.581632 → 54.657703 with `:d` and `:c`
   attached, and there is no `Slave status change` on link 1 or 2 anywhere after 49.169657.
   A DSP firmware boot does not, per se, evict an attached TAS2783. (Caveat: 76 ms vs 160 ms —
   almost certainly an IMR restore that skips the code-loader DMA.)
2. The rival alignment is not excluded. Detach minus `intel_link_power_up` is 166.595/165.943
   ms; minus `booting DSP firmware` is 156.760/157.501 ms. N=1 for both.

**NEW — the detach is selective.** `0x100`, not `0x110`: device 2 NPRESENT only
(`cadence_master.c:112-119`). `:a` and `:9` printed `Slave 2 state check1: UNATTACHED, status
was 1`; `:d` and `:c` printed nothing and stayed attached. Same link, same shim, same LCTL,
same crystal clock, enumerated ~0.5 ms apart — so no *deterministic* link-, shim- or
power-domain-granularity mechanism can be the whole story. The extent varies between boots
(05:09 lost all four), which is what a marginal event with per-device margin looks like; do not
write it up as a fixed position effect. Device number, unique_id and enumeration order are
**perfectly confounded**: the higher unique_id wins device-0 arbitration on both links every
boot (`3d…` before `3a…`, `3c…` before `39…`), so `:d`/`:c` are always device 1.

**The amp firmware download is not necessary for the detach.** `snd_soc_tas2783_sdw` is
blacklisted; its first line for `:a` is 46.324738 — **5.3 s after** the detach. No driver bound,
no `fid=` write, no `request_firmware` in flight. That retires "delay the download" as a
candidate fix.

**The survivors then worked.** `:d` downloaded `fid=0..51` from 46.327588, logged `No
calibration data in UEFI.` and `probe complete` at 47.671606; `:c` the same to 49.121591; both
downloaded again after the 49.17 re-enumeration. Both still `Attached`, `device_number=1`,
`runtime_status=active`. The kernel loaded `sof-sdca-2amp-id2.tplg` — **not a mismatch with
`cfg-amp:4`**: `sdca-%damp` is built from `dai_link->num_cpus`
(`sof-function-topology-lib.c:60`), and `num_cpus = hweight32(sof_dai->link_mask[stream])`
(`sof_sdw.c:923`) — the **link** count. Two links → `2amp` with four amps.

**AND THE BLOCKER MOVED. The failure is no longer "no amps".** A `Speaker` PCM exists at
`hw:1,2` and fails to open with `-22`, four gates deep:

1. `:a`/`:9` are UNATTACHED with `runtime_error` latched at `-ETIMEDOUT`
   (`tas2783_sdca_dev_resume`, `tas2783-sdw.c:1090-1095`; logged 54.460855/54.462296; stored by
   `rpm_callback`, `power-runtime.c:472-473`).
2. `rpm_resume` short-circuits to `-EINVAL` (`power-runtime.c:795-797`), so
   `snd_soc_pcm_component_pm_runtime_get()` — which walks **every** rtd component and tolerates
   only `-EACCES` (`soc-component.c:1183-1189`) — aborts the whole `SDW1-Playback-SmartAmp` BE
   at `soc-pcm.c:866`. Logged 54.893621-54.894002, and reproducible on demand with
   `aplay -D hw:1,2`.
3. Clearing the error alone does not help: `slave->unattach_request` is cleared only after a
   *successful* wait (`tas2783-sdw.c:1098`), so the next `pm_runtime_get` blocks 5000 ms
   (`TAS2783_PROBE_TIMEOUT`) and re-latches.
4. Past that, `tas_sdw_hw_params()` returns `-EINVAL` on `!fw_dl_success`
   (`tas2783-sdw.c:906-909`).

All four amps are codecs of **one** BE (`num_codecs = sof_dai->num_devs[stream]`,
`sof_sdw.c:924`; only `SDW1-Playback-SmartAmp` appears in the log), so **no mixer, UCM or DAPM
setting routes around the dead ones** — verified live: turning `Left/Right Spk2 Switch` off
changes nothing, because `pm_runtime_get` runs before DAPM.

**Ruled out this boot, each traced to source** (do not re-open): a host write to any SoundWire
link/shim/power register in the window (`.run` is `hda_dsp_cl_boot_firmware`; the only
SoundWire-directed write on that path is an interrupt *enable*, `mtl.c:204`); a shared
power-domain move (`mtl_dsp_pre_fw_run` sets `MTL_HfPWRCTL_WPIOXPG(1)` *before* the window and
never clears it); bus-clock/frame-shape reconfiguration (`cdns_init_clock_ctrl()` runs once per
bus start); an audio-PLL transient (`clock source 0` = `SDW_SHIM2_MLCS_XTAL_CLK` on all three
links); device-number collision; and `snd_soc_sof_sdw.quirk=` / `snd_sof.tplg_filename=` /
`disable_function_topology` as levers (the TAS2783 `codec_info_list[]` entry sets no `.quirk`,
and the runtime mach's only `sof_tplg_filename` is `sof-ptl-dummy.tplg`, which is not on disk).

**No upstream fix exists.** Verified 2026-08-27 against mainline: `loader.c` and `ptl.c` are
byte-identical to v7.1.9; `slave.c` differs only in an `of_property_read_string()` cleanup;
`intel_ace2x.c` only in BRA/BPT work. The `tas2783-sdw.c` diff touches firmware naming,
`writeable_reg`, `regcache_drop_region`, reg_default ordering and a resume rewrite that still
returns an error — and the detach provably predates the codec driver's bind by 5.3 s anyway.

## 3. The boot table — verified from the journal, not from notes

Blacklist (defect 3's workaround) installed 2026-08-26 16:24, first effective on boot -1.
Firmware symlinks created 2026-08-26 15:34, first effective on boot -2.

| Boot | Start | Defect 1 fixed | fw symlinks | blacklist | SoundWire dyndbg | what the log actually shows |
|---|---|---|---|---|---|---|
| -6 | 08-25 16:41 | no | no | no | no | fw requested for all four names *early*; amp state later unknown |
| -5 | 08-25 20:47 | no | no | no | no | same — and `:a` is dead by the first resume |
| -4 | 08-25 22:31 | no | no | no | no | same — `:a` dead by the first resume |
| -3 | 08-26 01:16 | no | no | no | no | same — `:a` dead by the first resume |
| -2 | 08-26 15:39 | **yes** | **yes** | no | from ~931 s only | first ignored write 92 ms before `Booted`; 14 157 `state check1` in the *later*, instrumented window |
| -1 | 08-26 16:25 | yes | yes | **yes** | **none** | no boot-time download failure; `:d`/`:c` downloaded cleanly; nothing else is observable |
| -1 | 08-27 05:09 | yes | yes | yes | **full** | **the only boot where the detach itself was captured**: all four NPRESENT at 46.2128, 93 ms before `Booted`, never returning |
| 0 | 08-27 12:00 | yes | yes | yes | **full + `snd_sof` loader.c** | **the detach measured inside the DSP firmware boot** (+156.8 ms of 160.0 ms, −3.2 ms from `firmware boot complete`), bracketed below by a live PING read at +71.6 ms; **`0x100`, not `0x110` — only device 2 on each link died**; `:d`/`:c` survived, downloaded `fid=0..51`, still attached; a second DSP boot at 54.58 detached nothing; Speaker PCM exists at `hw:1,2` and fails to open with `-22` |

**Indices are relative to the boot you are reading this in.** The 08-27 12:00 boot shifted
every `journalctl -b -N` index by one. Cite wall-clock dates, not relative indices.

Read it as: **two boots on record actually observed the failure.** Every other row
is an inference from what a driver did or did not print. The column that matters most is
the last one — six of the seven boots were not instrumented for this.

Boot -1 is still the one bright spot: `:d` and `:c` completed a full firmware download with
no boot-time errors (the 1.186 s gap between the link-1 and link-2 probe pairs is a
*completion*, not a timeout — `TIMEOUT_FW_DL_MS` is **3000** ms, `tas2783-sdw.c:42`). Note
what that does *not* show: `Found Smart Amp function at index 0` is printed for
**UNATTACHED** peripherals too — boot 0 prints it for all four, each immediately followed by
`Peripheral status = unattached` — so it is not evidence that an amp is on the bus.

---

## 4. Traps — each cost time once, do not pay twice

- **`device_number = N/A` does not mean "never enumerated."** It is returned for *any*
  slave whose `status == SDW_SLAVE_UNATTACHED` without ever reading `dev_num`
  (`sysfs_slave.c:237-246`).
- **`-61` is `-ENODATA`** — `SDW_CMD_IGNORED`, the peripheral did not ACK (`bus.c:224-225`).
  Not a missing file, and *not* proof that the bus was dead: an amp that has just left the
  bus produces exactly the same error.
- **Never unbind a single `slave-tas2783` device either.** `tas_sdw_remove()` →
  `snd_soc_unregister_component()` deletes a component of an instantiated card and unbinds
  the **whole** card — Jack Out, Speaker, HDMI 1-3, Deepbuffer and mics. Root-only, so it
  costs a FIDO2 touch, and it does **not** clear `runtime_error`. Maximum blast radius, zero
  payoff.
- **`cmd_revert` is a full teardown, not an experiment undo.**
  `standalone/omnibook-speaker-fix:452-472` restores every `.stock` it finds — including
  `snd-soc-sdca.ko.zst.stock`, the working defect-1 fix and currently the only `.stock` on
  the system — drops the firmware symlinks and runs `undefer`. After a module experiment,
  undo that module by hand (`mv …ko.zst.stock …ko.zst; depmod -a 7.1.9-arch1-2`), or budget
  a third attended reboot.
- **Never unbind/rebind on a live card.** Tearing down `sof-soundwire` breaks the HDA HDMI
  codec, which cannot re-probe at runtime. You lose the whole card until reboot.
  `snd_soc_tas2783_sdw` currently has refcount 4 (four bound components), so
  `modprobe -r` will refuse anyway.
- **`fw with no files` is a consequence**, not a parsing bug: `tas2783_fw_ready()` breaks
  its per-file loop on the first failed write, leaving `cur_file == 0`.
- **`ping-probe.sh` cannot work on an amp already in PM error** — `pm_runtime_get*` returns
  `-EINVAL` without calling the driver.
- **`.idle_bias_on = 1`** in `soc_codec_driver_tasdevice` (`tas2783-sdw.c:1027-1038`) makes
  ASoC pin every amp `runtime_status=active` forever, which pins links 1 and 2 active
  forever, which pins links 1 and 2 active **once the sof_sdw card has bound**.
  It is not absolute: on the 08-27 12:00 boot links 1 and 2 each ran one runtime cycle during
  bring-up (`link.1 runtime_suspended_time=902`, `link.2=44`, both frozen since) and were
  additionally power-cycled by two aborted s2idle attempts — three full `intel_link_power_up`
  + re-enumeration cycles in all, at 43.24, 45.20 and 49.17. The mechanism exists but is spent
  by the time you have a shell, and `power/control` still offers no lever to fire another. Contrast link 3, which suspends normally.
- **`power/control` offers no "force suspend".** `on` is `pm_runtime_forbid()` (a get),
  `auto` is `pm_runtime_allow()` (the matching put); the pair returns you where you
  started. There is no sysfs lever that drops a held reference. Nothing under `power/` clears
  `runtime_error` either: `runtime_status` is `DEVICE_ATTR_RO` (`power-sysfs.c:179`) and only
  *prints* `"error"`, masking the real status (`power-sysfs.c:154-155`); `control_store`
  reaches only `pm_runtime_allow`/`forbid`. The only clearers in the kernel are
  `__pm_runtime_set_status()` (`power-runtime.c:1393`) and `pm_runtime_init()`
  (`power-runtime.c:1846`), and a `slave-tas2783` unbind reaches neither —
  `pm_runtime_reinit()` acts only when `runtime_status == RPM_ACTIVE`
  (`power-runtime.c:1874-1875`), and a failed resume leaves RPM_SUSPENDED. Root-free probe:
  if `runtime_suspended_time` advances at wall-clock rate while `runtime_active_time` is
  frozen and `runtime_status` reads `error`, the device is RPM_SUSPENDED with runtime PM
  enabled. Measured live: `:a` and `:9` have `runtime_active_time` frozen at 5306 ms.
- **Do not upgrade the kernel expecting a fix.** `find_sdca_function()`'s DC-value check is
  byte-identical at 7.1, 7.2 and master, so the OOT SDCA module is still required — and 7.2
  changed `sdca_parse_function()`'s signature, so it needs a rebase before it will build.
  Mainline `cadence_master.c` and `bus.c` contain **no retry or rescan work** for this;
  defect 4 is unfixed upstream. Mainline `tas2783-sdw.c` *has* moved a lot (fallback
  firmware names, a `writeable_reg` callback, `regcache_drop_region()` instead of
  `regcache_sync()` on attach, `sdw_slave_wait_for_init()`), none of it aimed at this.
- **Do not chase an ACPI asymmetry between the amps.** All four are described identically
  (`SWD1`=`:9`, `SWD2`=`:c`, `SWD3`=`:a`, `SWD4`=`:d`), and none of them has an ACPI power
  resource or `_PSx` (no `power_state` file, no `power_resources_*` under
  `/sys/bus/acpi/devices/device:*`).
- **`sudo` on this machine needs a physical FIDO touch** (`/etc/pam.d/sudo` opens with
  `auth sufficient pam_u2f.so cue authfile=...`). A `sudo` call with nobody at the keyboard
  hangs for minutes and then fails. Everything in § 6 was built around that.
- **THE ROOT FILESYSTEM IS UNLOCKED BY THE FIDO2 KEY.** `/proc/cmdline` carries
  `root=/dev/mapper/root` and `rd.luks.options=<uuid>=fido2-device=auto`. **A reboot does
  not come back on its own**: it parks at the key's PIN/touch prompt, or after the 30 s
  token timeout at a passphrase prompt. There is no session, no sshd and no new journal
  until a human is at the console. Install, reboot and verification are therefore **one
  attended sitting**, and any experiment whose revert needs a reboot is only reversible
  with a person present. This is the single most important operational fact in this file.
- **`TIMEOUT_FW_DL_MS` is 3000 ms** (`tas2783-sdw.c:42`), so `tas_io_init()` can block for
  up to **three seconds** in `wait_event_timeout()` (`:1168`) under
  `cdns->status_update_lock`. The 1.186 s seen in boot -1 is an observed completion, not
  the timeout — do not quote it as if it were the code's limit.
- **`Found Smart Amp function at index 0` does not mean the amp is on the bus.** It is
  printed from the codec probe for UNATTACHED peripherals as well; in boot 0 all four
  print it and the very next line for each is `Peripheral status = unattached`.
- **Dynamic debug is not a free variable.** Boot -2 (the 14 157-event storm) had it on and
  boot -1 (the clean one) had it off, so any comparison between those two boots is
  confounded — `dev_dbg` printk inside `cdns_update_slave_status_work()` runs under
  `cdns->status_update_lock`. It is still worth arming, because a boot without it teaches
  nothing, but say so when comparing boots.
- **A patched module is not a signed module.** The stock `.ko.zst` files carry `intree: Y`
  and a PKCS#7 signature; anything built here carries neither. Harmless (`sig_enforce=N`,
  lockdown `[none]`, Secure Boot off, and the tree is already tainted 12288 by the SDCA
  swap) — but never write "matches the stock module exactly".
- **Never `zstd -o` straight over a live `.ko.zst`.** An interrupted run leaves a truncated
  archive where the kernel will look for the module, and the failure mode is silent. The
  `install_module` helper in `standalone/omnibook-speaker-fix` compresses to a temp path,
  `zstd -t`s it, checks `vermagic`, keeps `.stock` exactly once, then renames.
- **`cp -rs` cannot be used to mirror `/usr/share/alsa/ucm2`** — it rewrites the stock
  *relative* symlinks (`conf.d/sof-soundwire/sof-soundwire.conf -> ../../...`) into absolute
  paths back into `/usr`, so the card's entry point resolves to the stock file and every
  override is silently ignored. `ucm-overlay build` walks the tree by hand instead.

---

## 5. >>> NEXT STEP <<< — ranked, session 6

**Read the FIDO2 trap in § 4 first.** Root needs the key, *and so does the reboot*.

**Statement of fact: nothing produces speaker sound in the current boot, and no root-free
action can.** The four gates are in § 2.5. The suspend/resume, `power/control`, mixer/UCM/DAPM
and driver-unbind routes have each been traced to source and closed. The queue below is the
fastest path to a boot that makes sound, not to sound now.

### RANK 1 — NOW. Root-free, reboot-free, zero risk. **DONE, session 6.**

- **1a. Preserve this boot.** `boot-20260827-1200/` holds `kernel.txt`, `sysfs.txt`, `pcm.txt`,
  `recorder.txt`. It is the only state on record with two amps attached *and* a completed
  firmware download, and every other item here can end it.
- **1b. Harden the UCM auto-gate.** `amps_up()` now also requires
  `power/runtime_status != error` — see § 6. `ucm-overlay.bak-session6` is the previous version.
- **1c. Build the endpoint-filter module** (RANK 3's patch) — build only, do not install.
  Building is root-free; deferring it wastes the sitting.

### RANK 2 — ONE ATTENDED SITTING, boot A. Root + reboot. **DO THIS FIRST.**

Add the instrumentation that is missing and re-roll the amp lottery in the same reboot.

```bash
sudo tee -a /etc/modprobe.d/omnibook-sdw-debug.conf >/dev/null <<'EOF'
options snd_sof_intel_hda_common dyndbg=+p
options snd_sof_intel_hda_generic dyndbg=+p
EOF
sudo reboot            # be at the console with the FIDO2 key
journalctl -k -b 0 | grep -E 'booting DSP firmware|Attempting iteration|Core En/ROM load|Firmware download successful|firmware boot complete|Slave status change|Peripheral [0-9] status|clock source'
```

**Proves:** whether the detach falls inside the code-loader DMA or inside the FW_READY wait —
the one thing the 3.2 ms measurement cannot say. Also gives N=2 on the selectivity (is it
always device 2?) and a second sample of detach-minus-power-up vs detach-minus-DSP-boot, which
discriminates the two surviving alignments. **Risk: low.** Revert is `rm` the two lines.
Caveat to state in the write-up: this adds printk inside the very window under study.

### RANK 3 — the only route to actual sound from the observed hardware behaviour.

Filter UNATTACHED peripherals out of the SmartAmp DAI link, so the BE is built from the
survivors alone. This works **only** because the card is composed long after the amps die:
machine select ran at 40.857829 (160.8 ms *before* the detach — a filter there is useless), but
`mc_probe` → `asoc_sdw_parse_sdw_endpoints()` → `create_sdw_dailink()` ran at ~49.12,
**8 s after**.

**Where:** `soc_sdw_utils.c`, in the per-endpoint loop, as a new unconditional test inserted
before the quirk skip. Neither existing skip fires for TAS2783: `check_sdca` requires
`adr_dev->num_endpoints > 1` and the TAS2783 entry has `.dai_num = 1`; the quirk branch needs
`dai_info->quirk`, which that entry does not set. Follow the existing `(*num_devs)--; continue;`
idiom so `codec_conf` bookkeeping stays balanced.

**Use a durable predicate, NOT `slave->status`.** `status` is transiently false for healthy
peripherals on every link resume — this boot the survivors read `Peripheral status = unattached`
at 49.166891/49.167262 and re-attached 2.6-3.0 ms later. `mc_probe` re-runs on every
deferred-probe retry and could land inside such a window and drop all four. Gate on
`dev->power.runtime_error != 0`, or on "unattached on two reads a few ms apart", and log every
dropped endpoint.

**Expected if ≥1 amp survives:** `cfg-amp:2`; topology name unchanged (link count = 2); a
2-codec `SDW1-Playback-SmartAmp`; the Speaker PCM opens. Ceiling is **two** speakers. If a boot
loses all four, `sof_sdw.c:930` drops the dailink and there is no Speaker PCM — the correct
outcome, already handled by the UCM gate.

**Risk — the largest on this list.** `snd_sof_intel_hda_generic` hard-depends on
`snd-soc-sdw-utils`. A module that fails to load takes `snd_sof_pci_intel_ptl` with it and
**card 1 never registers at all** — no headset jack, no HDMI 1-3, no mics, no deepbuffer; only
USB card 0 survives. Recovery is root + another FIDO2 reboot. It cannot make the machine
unbootable (`MODULES=()`, nothing sound-related in the initramfs). Install through
`install_module` (temp path → `zstd -t` → vermagic check → `.stock` kept once → rename); never
`zstd -o` over the live file. **Revert is targeted, NOT `omnibook-speaker-fix revert`** (§ 4):
`sudo mv …/snd-soc-sdw-utils.ko.zst{.stock,} && sudo depmod -a 7.1.9-arch1-2 && sudo reboot`.

### RANK 4 — a later sitting, diagnostic only. DSPless.

```bash
echo 'options snd_sof sof_debug=0x8000' | sudo tee /etc/modprobe.d/zz-sof-dspless.conf
sudo reboot
journalctl -k -b 0 | grep -E 'Switching to DSPless|booting DSP firmware|Slave status change'
sudo rm /etc/modprobe.d/zz-sof-dspless.conf && sudo reboot     # second attended reboot
```

**Proves:** whether the DSP-enable path is *necessary*. The links still start (`hda.c:911-913`
gates `hda_sdw_startup()` only on `hw_ip_version >= SOF_INTEL_ACE_2_0`, no dspless test) while
`core.c:469-471` skips `snd_sof_run_firmware()`. **Cost:** two attended reboots; that boot has
no DSP audio. Confounded — it also removes `mtl_dsp_pre_fw_run()`'s SoundWire power-gate write,
so only a *positive* result (amps still detach ⇒ DSP exonerated) is decisive. Use
`/etc/modprobe.d`, not the kernel cmdline: the cmdline lives inside the UKI (`ENABLE_UKI=yes`).

### DO NOT DO — each evaluated and rejected, session 6

- **`systemctl suspend` as a diagnostic.** Already answered: three full link power-downs and
  re-enumerations ran this boot (43.24, 45.20, 49.17), each returning `0x21` (device 1 only)
  with `No more devices to enumerate`. `:a`/`:9` never answered device 0 again. And it cannot
  give sound even in the best case — `runtime_error` survives any re-attach. It risks the two
  survivors for zero information.
- **Unbinding one `slave-tas2783`.** Unbinds the whole card; does not clear the error. § 4.
- **A PM-error-clearing helper module.** Only relocates the `-22` to `snd_soc_dai_hw_params()`.
- **Patching `tas2783-sdw.c` to no-op a dead amp.** Considered and rejected in favour of RANK 3:
  it would need `dev_resume`, `hw_params`, `port_prep` and the `sdw_stream_add_slave()` path all
  neutered, leaving a dead codec inside the aggregated SoundWire stream. Filtering the endpoint
  out is one change in one place.
- **ACPI/DSDT override.** `intel-quirk-mask` works at link granularity; each link carries one
  dead and one live amp. Costs a DSDT decompile + UKI rebuild, on the artefact that also carries
  the FIDO2 LUKS unlock.
- **`snd_soc_sof_sdw.quirk=`, `snd_sof.tplg_filename=`, `disable_function_topology=1`.** § 2.5.
- **`sof-order` and the `cadence` rescan re-arm.** Both now contraindicated — § 5.1.

### 5.1 The two staged experiments — BOTH: DO NOT INSTALL

**`cadence` rescan re-arm.** Its mechanism already ran three more times this boot, for free, and
returned nothing: `Peripheral 2 status` appears exactly twice in the whole boot (40.933100,
40.933460) and never again, while the post-detach rescans at 45.196468, 45.228615 and 49.276587
print `Peripheral 1 status: 1` alone — and the print is gated on a non-zero status
(`cadence_master.c:1020-1021`), so the absent line **is** the reading. Four full device-0 sweeps
found only `3d…`/`3c…`. `sdw_show_ping_status` reports `0x4` on both masters at 54.4757. Also
`cdns_peripheral_missing()` keys on `dev_num_sticky`, never cleared here, so the retry would run
its full 20 × 250 ms on every bus start and can drive `tas_io_init()`'s SW reset + 3 s blocking
download onto the two survivors. Keep for upstream, with the corrected rationale (§ 9).

**`sof-order`.** Passes § 5's old letter and fails on substance:
1. `snd_sof_dsp_post_fw_run()` is `loader.c:171` — it relocates link start to ~5.7 ms **after**
   the instant the amps died, still inside the ~103 ms of post-boot work. It lands on the edge
   of the window, not clear of it.
2. Its premise is falsified: the second DSP firmware boot at 54.58 detached nothing.
3. Its header's evidence is now false ("every amplifier reports NPRESENT", "none ever
   re-attaches").
4. It destroys the DSPless control arm (`core.c:469-471` skips `snd_sof_run_firmware()`, so
   `post_fw_run` never runs and no link is started).
5. It makes `hda_sdw_startup()`'s `if (pdata->machine && !mach_params.link_mask) return 0;`
   (`hda.c:241-242`) live for the first time — at the current call site `pdata->machine` is NULL
   (`core.c:375` precedes `core.c:382`), so a zero mask would silently produce a card with no
   links.

If it is ever rebuilt: add a dspless carve-out, log `mach_params.link_mask` before calling
`hda_sdw_startup()`, and rewrite the header comment.

### And while root is available, take the two readings that are otherwise unreachable

```bash
sudo cp /sys/firmware/acpi/tables/{DSDT,SSDT*} ~/.local/share/omnibook-speaker-fix/acpi/
sudo cat /sys/kernel/debug/soundwire/master-0-*/intel-sdw/intel-registers
```
The DSDT settles whether the four amps share a power resource. **The ordering constraint on the
debugfs read is retired** — links 1 and 2 have now runtime-suspended, so there is no longer a
datum to protect and it can be taken at any point.

## 6. The UCM last mile — SOLVED, root-free, and already armed

Independent of defect 4, `alsa-ucm-conf` 1.2.16.1 would still give this card no speaker
sink, because it has no `tas2783` profile *and* the card advertises no `spk:` token:

```
Components : 'HDA:80862822,80860101,00100000  cfg-amp:4 iec61937-pcm:7,6,5 hs:rt712 mic:rt712'
                                            ^^ the gap where " spk:tas2783" belongs
```

The TAS2783 entry in `codec_info_list[]` (`sound/soc/sdw_utils/soc_sdw_utils.c`) is the
**only amp entry with no `.component_name`** — 17 others have one — and
`asoc_sdw_rtd_init()` appends `" spk:%s"` only when that field is set. So `SpeakerCodec1`
and `SpeakerCodecFile` stay empty and both UCM includes are skipped by their `Empty`
guards. **A `tas2783.conf` alone would have changed nothing.** (The one-line kernel fix,
worth sending upstream: `.component_name = "tas2783"`.)

Three files under `ucm/`, all commented with where each fact came from:
- `sof-soundwire/sof-soundwire.conf` — stock plus a block that recovers the codec identity
  from a `ControlExists` probe on `tas2783-1 Speaker Volume`, and `tas2783` added to the
  `/codecs/` include filter.
- `sof-soundwire/tas2783.conf` — the `SectionDevice."Speaker"`, PCM `hw:${CardId},2`,
  each DAPM pin guarded by `ControlExists` (the control is `Left Spk Switch`, **not**
  `Left Spk`; one failing `cset` aborts the whole sequence).
- `codecs/tas2783/init.conf` — the ctl-remap folding `tas2783-1..4 Speaker Volume` and the
  four pin switches into one stereo `tas2783 Speaker` element.

`ucm-overlay` deploys them with **no root at all**: alsa-lib honours `$ALSA_CONFIG_UCM2` as
a complete replacement for `/usr/share/alsa/ucm2`, so `ucm2/` here is a symlink farm of the
stock tree with only those three files real — package upgrades are picked up
automatically, and `ucm-overlay status` reports drift.

```bash
ucm-overlay build|check|enable|disable|auto|status
```

**Verified today, twice, independently:** `alsaucm dump text` exits 0 with empty stderr;
`list _devices/HiFi` gains a 7th entry `6: Speaker` and loses none of the six stock ones;
the remapped element reports `pvolume pswitch`, Front Left/Front Right, 0-200, 0.00 dB at
200, `[on]` against the real controls.

**It is deliberately NOT enabled yet.** A Speaker device that UCM offers with no amplifier
behind it becomes a *silent default sink*, which is strictly worse than having none. Instead
`~/.config/systemd/user/omnibook-ucm-overlay.service` (installed and enabled, user scope,
no root) runs `ucm-overlay auto` at every session start: it enables the overlay only when every TAS2783 on the bus reports `Attached`
**and** `power/runtime_status != error`. The `Attached` test alone is insufficient: nothing in
the SoundWire core clears `runtime_error` on re-attach (`sdw_handle_slave_status`'s only PM
action is `pm_request_resume()` at `bus.c:2015`, which returns `-EINVAL` off the latch), so an
amp can read `Attached` and still fail the PCM open with `-22` — exactly the silent broken
sink this gate exists to prevent. Hardened 2026-08-27 (session 6), and disables it again if they go away. So
the moment defect 4 is fixed, the speaker sink appears by itself.

---

## 7. Safety and revert

Nothing here touches the boot path. `snd-soc-sdca` and `soundwire-cadence` are both
loadable modules (zero hits in `modules.builtin`), `CONFIG_MODULE_SIG_FORCE` unset,
`sig_enforce=N`, lockdown `[none]`, Secure Boot off, `MODULES=()` in `mkinitcpio.conf` with
no soundwire in the autodetect set, so no initramfs is involved. Worst case is no audio
until the stock modules are restored — the USB headset (card 0) is unaffected either way.

```bash
sudo ~/.local/share/omnibook-speaker-fix/standalone/omnibook-speaker-fix revert
sudo reboot
```

`revert` restores every `.stock` module it finds (SDCA, Cadence and both SOF modules),
drops the firmware symlinks, removes the deferral and removes the boot recorder.

**But the revert is only as reachable as the reboot.** Root is FIDO2-unlocked and so is
the root filesystem, so a machine left in a broken state stays broken until somebody is at
the console with the key. That is why `install` contains nothing that can break the card,
and why both module-swap experiments sit behind their own subcommand.

If card 1 is missing after an experiment, reboot; `modprobe -r snd_soc_sof_sdw` is usually
not enough.

To take the UCM overlay out (no root):
```bash
systemctl --user disable --now omnibook-ucm-overlay.service
~/.local/share/omnibook-speaker-fix/ucm-overlay disable
```

---

## 8. Files here

| Path | What |
|---|---|
| `STATE.md` | this file — the persistent record |
| `STATE.md.bak-session4`, `.bak-session3` | earlier versions; session 4's is wrong in places, see § 2.0 |
| `standalone/` | the portable bundle: `omnibook-speaker-fix` + `README.md` + `patches/` |
| `sdca-build/` | v7.1.9 `sound/soc/sdca/` + the patched `sdca_functions.c`. Installed. |
| `sdw-utils-build/` | v7.1.9 `sound/soc/sdw_utils/` + `omnibook-filter-unattached-amps.patch` (drop SmartAmp endpoints whose peripheral is off the bus). **BUILT AND VERIFIED, NOT INSTALLED** — vermagic, `depends:` and the 58-symbol export surface all identical to stock; only new externals are `param_ops_bool` and `wait_for_completion_timeout`, both from vmlinux. `sitting.sh install|revert|verify` |
| `cadence-build/` | v7.1.9 `cadence_master.{c,h}` + the rescan re-arm patch, built, **not installed** |
| `sof-sdw-order/` | `src/` — a self-contained v7.1.9 tree for the two SOF modules, plus `sof-sdw-start-after-fw-boot.patch`. Builds warning-free; `depends:` identical to stock. **Not installed** |
| `acpi/` | where to put the DSDT/SSDT dump the next root window should take |
| `ucm/`, `ucm2/`, `ucm-overlay`, `ucm-test.sh` | the UCM last mile (§ 6) |
| `sdw-trace.sh` | dyndbg arm/disarm + trace report. **Armed.** |
| `boot-20260827-1200/` | the preserved evidence of the two-amp boot: `kernel.txt`, `sysfs.txt`, `pcm.txt`, `recorder.txt` |
| `ucm-overlay.bak-session6` | the pre-hardening `amps_up()` (status-only gate) |
| `apply-speaker-fix.sh` | session-3 script: build + install patched SDCA, firmware links, `--revert` |
| `probe-fw-download.sh`, `ping-probe.sh` | dead ends, kept for the notes in § 4 |
| `sof-topology-fix/`, `sof-sdca-4amp-id2.tplg` | for reporting upstream, not needed here |

Kernel sources for reading are cached at `~/.cache/linux-src/v7.1.9/` (flat files),
`~/.cache/linux-src/v7.1.9-extra/` (`ptl.c`, `lnl.c`, `hda-dsp.c`) and
`~/.cache/linux-src/master/` (mainline, for diffing).

Repo side (branch `dev` of `~/.omnibook`, commits `b9c487b`, `3e0cdd3`):
`bin/omnibook-speaker-firmware` and README > *Laptop speakers*. Only the firmware-symlink
half belongs in the repo — the kernel modules, the systemd units and the UCM overlay are
machine- and kernel-version-specific and must not ship to other users.

---

## 9. Upstream

Trackers, all open, none answered, **nothing filed by us**:
thesofproject/linux **#5877** and **#5802** (this exact board), **#5816** and **#5760**
(sibling HP chassis), Launchpad **#2143870**.

**#5824** (ASUS ProArt PX13, AMD manager, two TAS2783 on one link) is the closest match to
defect 4 and nobody has connected it to the HP reports: *only the second amp fails, the
first one's download always completes, and the identical download succeeds on a quiescent
bus.* A different manager with the same symptom is the strongest argument that the fix belongs
*below* Intel/SOF — but **not** at the Cadence layer: AMD's manager does not use it
(`modinfo -F depends soundwire-amd` → `soundwire-bus,soundwire-generic-allocation,snd-pcm,snd-soc-core`).
The only code shared with an AMD box is `soundwire-bus` (`bus.c`/`slave.c`) or the TAS2783
peripheral driver / the silicon itself. Frame the report as the shared **bus** layer, and note
that on 08-27 12:00 the HP board reproduced #5824's exact asymmetry — the second-enumerated
amp on each link died, the first survived and completed its download.

Three things worth sending upstream once the trace confirms them:
1. ~~`.component_name = "tas2783"` in `codec_info_list[]`~~ — **ALREADY UPSTREAM.** Verified
   2026-08-27 against mainline `soc_sdw_utils.c`: the TAS2783 entry now carries both
   `.is_amp = true` and `.component_name = "tas2783"`. Nothing to file. The matching
   `alsa-ucm-conf` files from `ucm/` are still worth sending to alsa-project.
2. The Cadence rescan re-arm (`cadence-build/sdw-cadence-rearm-attach-rescan.patch`),
   attached to #5877 and cross-referenced to #5824.
3. `tas_io_init()` blocking up to 3 s in `wait_event_timeout()` while holding
   `cdns->status_update_lock`, which stalls every other peripheral on the same link. That
   is a bug regardless of whether it is *this* bug.

#5760 was resolved by a BIOS emitting `mipi-sdca-control-dc-value`, which would retire the
OOT SDCA module entirely — worth re-checking HP for a BIOS newer than Insyde F.06.
