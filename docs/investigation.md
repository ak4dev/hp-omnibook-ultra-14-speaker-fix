# The research record

This is the raw, session-by-session investigation log, carried over verbatim from the
working notes. It is the authoritative account of *how* each conclusion was reached and
which earlier conclusions were overturned.

The distilled, current-truth versions live in the other files in this directory —
[defects.md](defects.md), [traps.md](traps.md), [userspace.md](userspace.md),
[ucm.md](ucm.md), [experiments.md](experiments.md), [upstream.md](upstream.md),
[porting.md](porting.md). Prefer those. Read this one when you need the derivation, the
measurements, or the history of a reversal.

> **Path references below are historical.** This record was written while the work lived in
> a scratch directory under `~/.local/share/`, before it was distilled into this repo, so it
> names paths like `sdca-build/`, `sdw-utils-build/`, `standalone/` and `ucm-overlay` that
> no longer exist. The mapping is: `sdca-build/` → `kernel/sdca/`, `sdw-utils-build/` →
> `kernel/sdw-utils/`, `cadence-build/` → `kernel/cadence/`, `standalone/` → `bin/`,
> `ucm/` → `userspace/ucm/`, `boot-*/` → `archive/boots/`. Tool names lost their old prefix.
> Kernel source line numbers are Linux 7.1.9 throughout.

---

# Laptop speakers (TAS2783 SoundWire) — persistent state

**Last updated: 2026-08-27, session 8.** This file is the authoritative, reboot-surviving
record. It lives outside `/tmp` on purpose (`/tmp` is tmpfs here). Read it first.
Session 4's version is kept as `STATE.md.bak-session4` (**large parts wrong** — see § 2.0);
session 5's as `.bak-session5`, session 6's as `.bak-session6`, session 7's as `.bak-session7`.
**Session 7 got sound out of the speakers.** It rewrote § 0 and § 5 and added § 2.6.
**Session 8 took the outstanding reboot, found the speakers came up silent, and fixed the
cause — which was ours.** It added § 6.2, rewrote § 6.1, updated § 0, § 4 and § 5 RANK 1.

Companion documents in this directory:
- `standalone/README.md` — the portable fix for a *new* device.
- `sdw-trace.sh` — `arm`/`disarm` dyndbg for the SoundWire stack, `report` the enumeration
  trace, `state` the whole stack. The working tool. **Currently ARMED.**
- `ucm-overlay` — the ALSA UCM last mile, root-free. See § 6.
- `cadence-build/` — an out-of-tree `soundwire-cadence.ko` with the rescan re-arm patch.
- `sdca-build/` — the out-of-tree `snd-soc-sdca.ko` that gets past the BIOS defect.

---

## 0. Where this stands in one paragraph

**THE SPEAKERS MAKE SOUND.** Confirmed by ear on 2026-08-27 (session 7, boot 14:04), through
`aplay -D hw:1,2` and then through PipeWire as a normal default sink. Defects 1 and 2 stay
fixed; defect 3 does not exist as diagnosed; **defect 4 is worked around, not fixed** — the
RANK 3 endpoint filter (`snd-soc-sdw-utils.ko`, `filter_unattached_amps=Y`) drops the two
amplifiers that leave the bus, so the SmartAmp BE is built from the survivors alone and the
Speaker PCM opens. RANK 2's measurement was also taken and **answers its question**: the detach
falls **inside the FW_READY wait, 66 ms after the code-loader DMA has stopped** and 3-4 ms
before `firmware boot complete` (§ 2.6). What you get is **mono from the left-hand speakers**:
the two amps that die on every boot are device 2 on each link, and device 2 on each link is the
**right-side pair** — measured by ear, § 2.6. That is the hardware ceiling until defect 4 is
actually fixed. The remaining open items are the *mechanism* of defect 4 and one unexplained
userspace fact: PipeWire's ACP layer builds **no HiFi profile at all** for this card, so the
working sink is a direct PipeWire node, not UCM (§ 6).

**Session 8, the 15:18 boot — the reboot was taken and the repair survived it.** Every RANK 0
piece came through intact (audited item by item), the "Laptop Speakers" sink came back on its
own, and the user confirmed sound by ear: still mono, still the left-hand pair. Two things
came out of it. (a) `10-omnibook-wait-for-card.conf` is **proven**, not merely untested — the
race happened and the drop-in absorbed it (§ 6.2). (b) The speakers came up **silent**: all
four DAPM pin switches read `off`, and the cause was **our own UCM overlay** muting them at
every card creation. Diagnosed, fixed and demonstrated A/B without a reboot — § 6.2. That
also finally explains § 6.1's long-standing "why does ACP build no HiFi profile", and the
answer turns out to be protective rather than a bug to fix.

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

### Defect 4 — the amplifiers leave the bus and never return. **WORKED AROUND, NOT FIXED.**

**Session 7 status first, because the rest of this section was written while it was the wall.**
The mechanism is still unknown, and the two amps still die on every boot. What changed is that
they no longer take the speakers with them: the RANK 3 endpoint filter drops them from the
SmartAmp DAI link, the BE is built from the survivors, and the Speaker PCM opens and plays.
The cost is the entire right-hand side — device 2 on each link is the right-side pair (§ 2.6).
RANK 2's measurement has since placed the detach inside the FW_READY wait, ruling out the
code-loader DMA; read § 2.6 before § 2.5, and both before the narrative below.

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

### 2.6 The 2026-08-27 14:04 boot — RANK 2 answered, and the day it made a noise

**Session 7.** Same instrumentation as § 2.5 *plus* `snd_sof_intel_hda_common` and
`snd_sof_intel_hda_generic` at `+p` — the two modules RANK 2 asked for. Monotonic timestamps:

```
19.454017  link.1 clock source 0 LVSCTL 0x0            intel_link_power_up
19.459079  :d signaling initialization completion      SURVIVOR
19.460476  :a signaling initialization completion      DIES
19.463977  :c signaling initialization completion      SURVIVOR
19.464819  :9 signaling initialization completion      DIES
19.473970  booting DSP firmware                        loader.c:138
19.474866  Attempting iteration 0 of Core En/ROM load...
19.475022  Code loader DMA starting
19.475207  waiting for FW_ENTERED status
19.558018  link.1 Peripheral 1 status: 1               LIVE CDNS_MCP_SLAVE_STAT read
19.558366  link.1 Peripheral 2 status: 1               :a still ATTACHED here
19.566283  link.2 Peripheral 1 status: 1
19.566509  link.2 Peripheral 2 status: 1               :9 still ATTACHED here
19.569342  Code loader FW_ENTERED status
19.569845  Code loader DMA stopped
19.570109  Firmware download successful, booting...    <-- THE DMA IS OVER
19.636011  link.1 Slave status change: 0x100           <-- DETACH, +65.9 ms
19.637029  link.2 Slave status change: 0x100           <-- +66.9 ms
19.640058  firmware boot complete                      loader.c:167, -4.0 / -3.0 ms
19.730024  Booted firmware version: 2.14.1.1
```

**RANK 2's question is answered: the detach is NOT in the code-loader DMA.** It is 65.9 /
66.9 ms *after* `Code loader DMA stopped`, inside the FW_READY wait
(`wait_event_timeout(sdev->boot_wait, ...)`, `loader.c:154`). Only 11.7 ms (link 1) and 3.6 ms
(link 2) of the bracketed window overlaps the tail of the DMA; the other ~66 ms does not.

**And it discriminates the two surviving alignments.** With N=2 boots (4 link-events):

| reference | 12:00 boot | 14:04 boot | spread |
|---|---|---|---|
| `firmware boot complete` | −3.214 / −2.473 ms | −4.047 / −3.029 ms | **1.57 ms** |
| `booting DSP firmware` | +156.760 / +157.501 | +162.041 / +163.059 | 6.3 ms |
| `intel_link_power_up` (per link) | +166.595 | +181.994 / +180.033 | ~15 ms |

`firmware boot complete` — the instant the DSP signals FW_READY — is by an order of magnitude
the tightest predictor. The amps die **3.2 ± 0.8 ms before the host is told the firmware is
ready**, which points at the last few milliseconds of the DSP firmware's own init, not at
anything the host driver does. **Caveat, stated because it is real:** the `Slave status change`
print comes from `cdns_update_slave_status_work()` on a workqueue
(`schedule_work(&cdns->work)` in `sdw_cdns_irq()`), so an unmeasured scheduling latency sits
between the hardware event and the print. That shifts every number in the same direction and
cannot manufacture the *tightness*, but it does mean the true offset is ≥ 3.2 ms.

**Selectivity is reproducible, not a lottery.** `0x100` on both links again — device 2 dies,
device 1 survives, identical to the 12:00 boot. Two for two.

**THE PHYSICAL MAPPING — measured by ear, session 7, and it explains the whole thing.**
Isolating each surviving amp with its own DAPM pin switch and playing a distinguishable sweep
through each:

- amp `:d` (link 1, device 1, `tas2783-2`, DAPM pin "Right Spk")  → **left-hand speaker**
- amp `:c` (link 2, device 1, `tas2783-4`, DAPM pin "Right Spk2") → **left-hand speaker**

Both survivors are on the **left**. So **device 1 on each link is the left-side pair and device
2 on each link is the right-side pair**, and the selective detach kills precisely the entire
right side, every boot. The kernel's `name_prefix` → pin mapping in
`asoc_sdw_ti_spk_rtd_init()` (`soc_sdw_ti_amp.c:57-64`, tas2783-1→"Left Spk",
-2→"Right Spk", -3→"Left Spk2", -4→"Right Spk2") does **not** describe this chassis: both
amps it calls "Right" are physically on the left. Do not trust those names for anything.

**Stream-channel routing after the filter.** Both survivors receive stream **channel 0**:
a sweep in the LEFT channel of `hw:1,2` is audible, a sweep in the RIGHT channel is silent.
So a plain stereo open discards every right-channel sample — hence the summing PCM in § 6.

**What actually happened when it played.** The full path executed, first try:

```
cmd=0 dai SDW1 Pin2 direction 0                       link 1 DAI port opened
cmd=0 dai SDW2 Pin2 direction 0                       link 2 DAI port opened
:d Configured bus base 1, scale 3, curr_freq 4800000  audio frame rate
:c Configured bus base 1, scale 3, curr_freq 4800000
:a Not enumerated, skip programming BUSCLOCK_SCALE    dead amps harmlessly skipped
:d / :c Peripheral status = alert -> attached
```

No `-22`, no `error playback without fw download`. **The `-22` that IS in this boot's log, at
22.844, is a race and not a defect**: something opened the Speaker PCM 0.4 s before `:c`
finished its firmware download (`:d` completed fid=0..51 at 22.109, `:c` at 23.247). Both amps
downloaded the identical 52-file set and both printed `probe complete`. Do not re-diagnose that
line as gate 4 coming back.

**Gates 1-3 of § 2.5 are cleared by the filter and gate 4 never fires** once both survivors
have finished downloading. `runtime_error` on `:a`/`:9` is now never latched at all this boot
(`power/runtime_status` reads `suspended`, not `error`) because nothing ever tries to resume
them — they are no longer codecs of the BE.


### 2.7 Session 8 — five corrections to this file, and the recovery question CLOSED

Five load-bearing claims in §§ 2.4-2.6 and § 3 are wrong. § 2.0 exists because this keeps
happening; this is the same entry for session 8.

1. **`0x110` is NOT "the two dev-2 amps".** One nibble per device (`cadence_master.c:114-119`),
   so `0x110` is device 1 **and** device 2. The 05:09 boot's own next lines say so:
   `:d` *"Slave 1 state check1: UNATTACHED"* and `:a` *"Slave 2 state check1: UNATTACHED"*,
   and the same on link 2 for `:c`/`:9`. **On the 05:09 boot all four amps left the bus**,
   survivors included. So **selectivity is 3 of 4 instrumented boots, not 4 of 4**, and
   *"one complete physical side, symmetrically"* is **not an invariant**. Do not file it
   upstream as one — it is disproved by this machine's own log.
2. **The "+65.9/66.9 ms after `Code loader DMA stopped`, N=2 boots" of § 2.6 is an N
   inflation.** Those are the two *link events of one boot*. With the real N=2 boots it does
   not replicate: +66.17/+67.18 ms on one, **+23.14/+24.05 ms** on the other. Range 44 ms.
   The conclusion (the code-loader DMA is excluded) survives; **the number must never be
   quoted.** What *does* replicate is the other end: the detach sits **−2.98 ± 0.61 ms from
   `firmware boot complete`** across three boots whose total DSP boot lengths were 166.1,
   166.0 and 160.0 ms and whose DMA sub-phase varied by 43 ms. The detach tracks the *end of
   the DSP firmware boot*, not the DMA.
3. **Every absolute timestamp quoted for the 05:09 boot is offset by a constant +31.9448 s**
   from the journal (46.2128 → 14.268024, 46.1438 → 14.199047, 46.0388 → 14.094018 — the
   offset is identical to four decimals). Intervals are valid; absolute citations are not.
   The three post-detach rescans at 45.196468 / 45.228615 / 49.276587 are the **12:00** boot,
   not 05:09.
4. **"Once an amp goes NPRESENT there is no recovery path" is false as stated.** Every bus
   restart re-arms `cdns_check_attached_status_dwork`. `:c` and `:d` **have** recovered from
   NPRESENT, repeatedly. The true statement is narrower and stronger: **`:a` and `:9` have
   never recovered on any boot on record.**
5. `sdw_clock_stop_quirks` is a parameter of **`snd_sof_intel_hda_generic`**, not
   `snd_sof_intel_hda_common`.

**THE RECOVERY QUESTION IS CLOSED — by a completed s2idle, and the user did it by accident.**
At 15:33:08 on the 15:18 boot the lid was closed and at 15:33:33 opened again (`systemd-logind:
Lid closed / Suspending... / Lid opened`). That is the experiment nobody had ever run: a
**completed** suspend/resume with the card bound. It exercises the strongest reset the kernel
possesses — controller to D3, **all three links powered down** (`first link up, programming
SYNCPRD` only prints when `*shim_mask == 0`), Cadence soft reset, bus `HW_RST`, and a full
device-0 re-enumeration sweep with **no DSP firmware running**. The survivors `:d` and `:c`
were hard-reset back through device 0 and re-downloaded their entire firmware.
**`:a` and `:9` did not answer**: `Msg ignored for Slave 0` → `No more devices to enumerate`
on both links. There is no stronger lever in the kernel. **Suspend/resume is not a workaround,
and no reset-based recovery is going to work.**

**The genuinely new finding, and the sharpest thing this machine has to offer upstream: the
dying amps are MARGINAL, not absent.** On the 14:04 boot `:9` re-announced at device 0 **214
times**, returned its own correct DEVID `390102000001` **31 times**, and was re-assigned
device number 2 (`Slave already registered, reusing dev_num: 2`) **24 times** — then failed
its *first register transaction* every time, with `-EIO` and a parity error. Seven of its
DEVID reads came back **bit-corrupted** (`0x39` → `0x29`, `0x31`, `0x28`); no such corruption
was ever logged for `:d`, `:c` or the RT712. Two of those corruptions did not match under
`sdw_compare_devid()` (`bus.c:712`, which ignores `sdw_version`) and so manufactured two
**phantom devices**, `sdw:0:2:0102:0000:01:1` and `...:8`, which then logged for the rest of
the boot. **Detection is not the failure; register I/O is.** That is a device-margin /
link-margin signature on link 2, and it is unreported anywhere upstream.

**A bus-clock experiment was proposed on the strength of this and is FALSIFIED — do not run
it.** The idea was that the bus runs at 9.6 MHz at idle and 4.8 MHz during a stream, and that
every recovery had been attempted at 9.6. It is wrong: **768 of 773 `curr_freq` samples on the
14:04 boot are 4,800,000** — the bus dropped to 4.8 MHz at t=22.68 and stayed there, so every
corrupt read and every failed re-enumeration happened **at the lower clock**, while the
survivors were fine at that same clock. Also rejected: `sdw_mclk_divider` is a trap (`=4` gives
19.2 MHz, *faster*; `=1` divides none of the four bases in `sdw_slave_set_frequency()` and
enumeration fails outright), and a parity-retry in `sdw_program_device_num()` would manufacture
more phantom devices, as already happened twice.

---

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
| -1 | 08-27 12:00 | yes | yes | yes | **full + `snd_sof` loader.c** | **the detach measured inside the DSP firmware boot** (+156.8 ms of 160.0 ms, −3.2 ms from `firmware boot complete`), bracketed below by a live PING read at +71.6 ms; **`0x100`, not `0x110` — only device 2 on each link died**; `:d`/`:c` survived, downloaded `fid=0..51`, still attached; a second DSP boot at 54.58 detached nothing; Speaker PCM exists at `hw:1,2` and fails to open with `-22` |

| 0 | 08-27 14:04 | yes | yes | yes | **full + `snd_sof` loader.c + `hda_common`/`hda_generic`** | **RANK 2 answered**: detach 65.9/66.9 ms AFTER `Code loader DMA stopped`, inside the FW_READY wait, −4.0/−3.0 ms from `firmware boot complete`; `0x100` again — device 2 on each link, N=2 on selectivity; the RANK 3 endpoint filter installed and firing; **the speakers made sound** |

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
- **SHORT TONE BURSTS ARE NOT A VALID LISTENING TEST ON THESE AMPS.** This cost most of
  session 7's listening budget and produced three wrong conclusions in a row. 1.2-2.0 s
  bursts of a single 600 Hz tone were reported silent on an amplifier that a 6-8 s
  frequency sweep at the same amplitude then made "clearly" audible. The TAS2783 runs a
  smart-amp algorithm with its own gating/ramping, and short steady bursts do not reliably
  get through it. **Always test with a sweep of ≥5 s**, and treat any "silent" result from a
  burst as unproven. Two claims built on bursts — ":d is dead" and "the right channel might
  work" — were both wrong.
- **A completed s2idle does NOT bring the dead amps back** — measured 15:33 on the 15:18 boot,
  § 2.7. It is the strongest reset in the kernel and it fails. Do not spend another session
  hoping suspend/resume is the workaround.
- **The failures are at 4.8 MHz, not 9.6.** Any "lower the bus clock" experiment is dead on
  arrival: 768 of 773 `curr_freq` samples on the 14:04 boot read 4,800,000. And
  `sdw_mclk_divider` is a trap — `=4` gives **19.2 MHz** (faster), `=1` divides none of the
  four bases in `sdw_slave_set_frequency()` and enumeration fails outright, taking the working
  pair with it.
- **`0x110` means devices 1 AND 2, not "the dev-2 pair".** One nibble per device. § 2.7.
- **Never quote STATE.md's absolute timestamps for the 05:09 boot** — they are offset +31.9448 s
  from the journal. Intervals are fine. § 2.7.
- **Our own UCM overlay muted the speakers at every boot** until session 8 (§ 6.2). Any
  `DisableSequence` in the overlay runs at *every* card creation via HiFi's `disdevall ""`,
  whether the device was ever enabled or not. Think twice before adding one back.
- **`ucm-overlay check` was silently useless when run from an enabled session** — the ambient
  `ALSA_CONFIG_UCM2` leaked into its "stock" side, so its one safety assertion compared the
  tree against itself. Fixed session 8 with `env -u`; if you copy this pattern elsewhere,
  carry the `env -u`.
- **`ucm-overlay enable` and `disable` both run `systemctl --user restart wireplumber`.** That
  is the audio-stack restart § 4 warns about. To change the overlay safely, edit `ucm/` and run
  `ucm-overlay build`, which touches no services; the change lands at the next card creation.
- **`amixer`'s simple mixer cannot see the TAS2783 controls.** `amixer -c 1 sset 'Right Spk
  Switch' on` fails with "Unable to find simple control". Use `cset numid=N` or
  `cset name='...'`. `amixer -c 1 controls` lists them; `amixer -c 1 contents` shows values.
- **Only the surviving amps register mixer controls.** On the 14:04 boot only
  `tas2783-2`/`tas2783-4` controls exist. Any config that names `tas2783-1` or `tas2783-3` —
  the UCM identity probe did — silently finds nothing. The four DAPM pin switches
  (`Left Spk`, `Right Spk`, `Left Spk2`, `Right Spk2`) all exist regardless: they are
  card-level widgets from `lr_4spk_widgets`, not per-codec controls.
- **The kernel's speaker names do not describe this chassis.**
  `asoc_sdw_ti_spk_rtd_init()` maps tas2783-1→"Left Spk", -2→"Right Spk", -3→"Left Spk2",
  -4→"Right Spk2". Measured by ear (§ 2.6), both amps it calls "Right" are physically on the
  **left**. Device 1 on each link is the left pair, device 2 the right pair.
- **A `-22` in a boot log is not automatically gate 4 coming back.** On the 14:04 boot
  something opened the Speaker PCM 0.4 s before `:c` finished its firmware download, giving
  `error playback without fw download` + `ASoC error (-22)`. Playback works fine afterwards.
  Check the download completion timestamps before diagnosing.
- **Never leave `.bak-*` files inside `ucm/`.** `ucm-overlay build` farms every file in that
  tree as an override; two backups turned "3 overrides" into "5". Backups go in
  `backups/session7/`.
- **`sudo` in a non-interactive shell fails even with the FIDO key present.** It prints
  "Please touch the FIDO authenticator", then falls back to a password prompt, then dies with
  "a terminal is required to read the password". Root commands must be run from a real
  terminal — in Claude Code, by the user typing `! <command>`.
- **A `context.objects` entry in `pipewire.conf.d` that cannot be created KILLS THE WHOLE
  PIPEWIRE DAEMON.** Not the node — the daemon. Observed 2026-08-27: with `hw:1,2` held by a
  leaked substream, `pipewire.service` died `240/LOGS_DIRECTORY` in 24 ms, hit its start limit,
  and the machine had **no audio at all** (not even USB) until the file was moved away. The
  log line is `conf.c create_object(): can't create object from factory adapter` followed by
  `pipewire.c main(): failed to create context`. **Always carry `flags = [ nofail ]`** —
  `/usr/share/pipewire/pipewire.conf:262-267`: *"If nofail is given, errors are ignored (and no
  object is created)."* Verified live against the wedged PCM: PipeWire logs the failure, skips
  the node, and stays up. Note the exit code is a red herring — 240 is systemd's
  `EXIT_LOGS_DIRECTORY` label for a code PipeWire chose itself; do not go looking for a
  `LogsDirectory=` problem, run `/usr/bin/pipewire` in the foreground and read the real error.
- **The Speaker PCM can be left wedged by a dead process, and only a reboot clears it.**
  After a `pipewire` restart cycle, `/proc/asound/card1/pcm2p/sub0/status` read
  `state: SETUP  owner_pid: 100379` with pid 100379 dead and reaped — a leaked ALSA substream.
  Every open then fails `Device or resource busy`, `aplay` included, with **no** process
  holding an fd on `/dev/snd/pcmC1D2p`. Nothing in userspace frees it: there is no sysfs lever,
  and unbinding the card is the § 4 maximum-blast-radius trap. Suspect this whenever the PCM is
  busy and no holder can be found, and do not mistake it for the amps having failed — check
  `status` and `power/runtime_status` on the two survivors, which stay `Attached`/`active`
  right through it.
  **It escalates.** Left alone the wedge spread from the PCM to the card's *control* interface:
  `amixer -c 1 controls` and `alsactl restore` then hang in **uninterruptible sleep (D state)**,
  which `timeout(1)` cannot kill and neither can `SIGKILL` — by the end of session 7 there were
  one `alsactl`, three `amixer` and one `aplay` parked in D. They are harmless but permanent
  until reboot. **The moment `hw:1,2` reports a dead `owner_pid`, stop touching card 1
  entirely** — every further `amixer`/`alsactl`/`aplay` just adds another unkillable process.
  PipeWire itself is unaffected as long as its ACP holds the card at profile `off` and the
  speaker node carries `nofail`; the rest of the machine's audio keeps working.
- **Restarting `pipewire` while the speaker node holds the PCM is what wedged it.** Prefer not
  to restart the audio stack while the Speaker sink exists; if the sink must be recreated,
  expect the wedge and budget a reboot.
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

## 5. >>> NEXT STEP <<< — ranked, session 7

**It works. Nothing below is required to keep sound working.** Everything here is either
"make it better" or "find out why". Read the FIDO2 trap in § 4 before anything needing root:
root needs the key *and so does the reboot*.

### RANK 0 — what is installed and must not be lost

| piece | where | what it does |
|---|---|---|
| patched `snd-soc-sdca.ko.zst` | `/lib/modules/7.1.9-arch1-2/kernel/sound/soc/sdca/` | defect 1: assume SmartAmp when the DC value is unreadable |
| patched `snd-soc-sdw-utils.ko.zst` | `/lib/modules/7.1.9-arch1-2/kernel/sound/soc/sdw_utils/` | **defect 4 workaround**: drop UNATTACHED SmartAmp endpoints |
| four firmware symlinks | `/usr/lib/firmware/updates/` | defect 2, managed by `~/.omnibook/bin/omnibook-speaker-firmware` |
| `~/.asoundrc` | `pcm.omnibook_spk` | sums both stream channels into channel 0, the one the amps read |
| `~/.config/pipewire/pipewire.conf.d/50-omnibook-laptop-speaker.conf` | | the "Laptop Speakers" sink, bound to `omnibook_spk` |
| `~/.local/bin/omnibook-speaker-mixer` + user unit | | restores the amp mixer state at session start |

**A kernel upgrade destroys both out-of-tree modules** — new `vermagic`, and the packaged
modules come back. Rebuild both before rebooting into a new kernel, or lose the speakers.
`sdca-build/` needs a rebase on 7.2 (`sdca_parse_function()` changed signature).

### RANK 1 — session 8. The reboot is DONE; these are what is left.

**The outstanding reboot was taken (15:18 boot) and everything survived it.** Every RANK 0
piece audited intact; the sink came back unaided; sound confirmed by ear — still mono, still
the left pair. Two results: `10-omnibook-wait-for-card.conf` is **proven** (it blocked
PipeWire 3.01 s and absorbed the race), and the speakers came up **silent** because our own
UCM overlay was muting the pins — diagnosed, fixed and demonstrated A/B (§ 6.2). The old RANK 1
item *"understand why ACP builds no HiFi profile"* is **answered** (§ 6.1) and the answer is
that the failure is protective: do not fix it.

**1. >>> PIN THE KERNEL. THIS IS THE ONLY TIME-CRITICAL ITEM IN THIS FILE. <<<**
`/etc/pacman.conf` has **no `IgnorePkg` at all**, and `pacman -Qkk linux` already reports both
out-of-tree modules as size/SHA mismatches — pacman owns those paths and **will overwrite both
silently**. `linux 7.1.10` is in core-testing (flagged out-of-date 2026-08-23) and 7.2.1
released 2026-08-27. The realistic trigger is `omarchy-update`, which runs a full system
upgrade. The next unheld `-Syu` + reboot takes **both** modules and **the left speakers go too**
— and the rebuild can only happen *after* the attended FIDO2 reboot that broke it. Run from a
real terminal, add under `[options]`:

```
IgnorePkg = linux
```

(7.2 additionally needs a *source rebase* of `sdca-build/` — `sdca_parse_function()` changed
signature. `linux-firmware` is safe to keep upgrading; 7.2's `e26bb459d0f3` would retire
`omnibook-speaker-firmware`.)

**2. Dump the ACPI tables — the one cheap read never taken.** `acpi/` is still empty, and
§ 4's *"do not chase an ACPI asymmetry"* is **inferred from sysfs and has never been checked
against the tables**. Look for `GpioIo` in `_CRS`, a `PowerResource`/`_ON`/`_OFF`, an EC
method, or any asymmetry between SWD1/SWD3 (the dying pair) and SWD2/SWD4. If it shows one,
a local lever exists after all and it jumps to the top of this list.

```bash
sudo cp /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT* ~/.local/share/omnibook-speaker-fix/acpi/
sudo chown -R "$USER" ~/.local/share/omnibook-speaker-fix/acpi/
```

**3. File upstream — the only route with a real chance of the right speaker.** § 9, rewritten
for session 8. New issue on thesofproject/linux, cross-linked into **#5877** (this exact board)
and bugzilla.kernel.org **#221782** (same board, same BIOS F.06). **Do not frame it via #5824** —
that AMD case was root-caused to `amd_manager.c:287`, the peripheral never leaves the bus there,
and unbind/rebind recovers it; framing it that way gets it dismissed. Lead with what nobody has
posted: the **marginal-link signature** (§ 2.7 — 31 clean DEVIDs, 24 device-number
assignments, first register write fails with parity, seven bit-corrupted DEVIDs, two phantom
devices), the **−2.98 ± 0.61 ms pin to `firmware boot complete`** across three boots and two
DSP-boot lengths, the **completed-s2idle negative result**, the RT712 negative control on the
same shim, and an offer to test pre-release patches on an instrumented box. Correct § 2.7's
five errors before filing anything.

**4. Verify at the next boot that the pins come up `on` unaided** (§ 6.2) — one command, no
setup:

```bash
for n in 14 15 16 17; do amixer -c 1 cget numid=$n | sed -n 's/^  : values=//p'; done
```

### RANK 2 — the mechanism of defect 4, now that RANK 2's own measurement is in

§ 2.6 puts the detach inside the FW_READY wait, 3.2 ± 0.8 ms before `firmware boot complete`,
with the code-loader DMA exonerated. The remaining discriminator is **RANK 4 of session 6,
DSPless** (`options snd_sof sof_debug=0x8000`): the links still start
(`hda.c:911-913` gates `hda_sdw_startup()` only on `hw_ip_version >= SOF_INTEL_ACE_2_0`) while
`core.c:469-471` skips `snd_sof_run_firmware()` entirely. Amps still detach ⇒ the DSP is
exonerated and the cause is elsewhere. Cost: two attended reboots, no DSP audio in between,
and it is confounded (it also removes `mtl_dsp_pre_fw_run()`'s SoundWire power-gate write), so
only a *positive* result is decisive. **This is now optional** — it buys understanding and an
upstream report, not sound.

### RANK 3 — get the right-hand speakers back. **Session 8 verdict: NOT LOCALLY FIXABLE.**

Asked directly by the user, session 8, and answered on measurement rather than argument.

**Recovery is closed.** The strongest reset the kernel has — controller to D3, all links down,
Cadence soft reset, bus `HW_RST`, full device-0 re-enumeration, no DSP firmware running — ran
on the current boot as a **completed s2idle** and `:a`/`:9` did not answer (§ 2.7). Nothing
weaker can work, and nothing stronger exists short of a platform reset, which buys ~19.6 s
before the detach recurs.

**Prevention needs the mechanism, and the mechanism is not ours to find.** No BIOS exists to
flash: F.06 (06/25/2026) is both what is installed and the newest HP has ever published for
board 8EB4; the complete lineage F.02 → F.03 → F.04 → F.06 has **no** changelog line touching
SoundWire, TAS2783, SDCA, ACPI/DSDT or speakers; it is not on LVFS and the extracted capsule
would be byte-identical to what is running. Intel's SoundWire maintainer has said on the
record that **HP and TI are working on a second, non-BIOS defect on this chassis and will
release kernel patches plus UCM** — that is the realistic route, and RANK 1 item 3 is how this
machine contributes to it.

**And note what "full stereo" actually needs — three things, of which we have one:**

| | |
|---|---|
| `:a`/`:9` stay on the bus | **unsolved — the whole problem** |
| SDCA function-type defect | **done**, out-of-tree `snd-soc-sdca.ko` |
| per-amp channel split, so the two sides get *different* channels | **unmerged upstream** (three competing series, Aug 2026) |

The first two without the third give **sound from the right speaker but still mono**. And the
corollary matters: **merging the stereo-split patches today would not help at all** — both
survivors are on the left, so it would split L/R across two left-hand drivers.

Do **not** try to route around it in userspace: there is no right-side amplifier to route to.

### RANK 4 — upstream

§ 9. The strongest material is now: (a) the two-boot bracketing in § 2.6 with the code-loader
DMA ruled out, (b) the physical mapping showing the failure takes out one complete side, and
(c) the cross-manager match with #5824. `.component_name = "tas2783"` is already upstream.

### DO NOT DO — still rejected, session 7

- **`sof-order` and the `cadence` rescan re-arm.** Both still contraindicated — § 5.1 stands
  unchanged, and § 2.6 does not revive either. `sof-order` in particular lands ~5.7 ms after
  the detach instant, i.e. on the window's edge, and its objection 5 (the `hda_sdw_startup()`
  `link_mask` landmine at `hda.c:241-242`) is unaddressed.
- **`omnibook-speaker-fix revert`.** § 4. It restores every `.stock` it finds, which now
  includes the working `snd-soc-sdw-utils.ko.zst.stock` — it would take the speakers away.
  Revert a single module by hand.
- **Unbinding anything on the live card.** § 4, unchanged.

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

## 6. The last mile — what actually delivers sound (session 7)

**The working sink is a direct PipeWire node, NOT the UCM overlay.** Read § 6.0 first; § 6.1
is the UCM work, which is still installed, still correct as far as it goes, and currently
**not what makes the speakers play**.

### 6.0 The userspace stack that works

Three root-free pieces, all under `$HOME`:

1. **`~/.asoundrc`** defines `pcm.omnibook_spk`: a `plug` over a `route` whose ttable sums both
   input channels into slave channel 0 at 0.5 each. Necessary because after the endpoint filter
   both surviving amps read stream **channel 0** (§ 2.6), so a plain stereo open of `hw:1,2`
   silently discards every right-channel sample.
2. **`~/.config/pipewire/pipewire.conf.d/50-omnibook-laptop-speaker.conf`** creates an
   `api.alsa.pcm.sink` adapter node named "Laptop Speakers" on `omnibook_spk`, 2ch FL/FR,
   **with `flags = [ nofail ]`, which is load-bearing — see the trap in § 4.**
   **Declaring the node MONO does not work** — with `audio.channels = 1` and
   `audio.position = [ MONO ]` the adapter still exposes `playback_FL`/`playback_FR`, `pactl`
   still reports `s32le 2ch`, and PipeWire routes FL only, so right-channel content is dropped
   exactly as with a raw stereo open. Verified live. Do the summing in ALSA, not in PipeWire.
   The ttable index order is `ttable.<client>.<slave>` — confirmed from
   `/usr/share/alsa/cards/ATIIXP-MODEM.conf`, which routes client channel 0 to slave channel 1
   as `ttable.0.1` — so `ttable.0.0 0.5` + `ttable.1.0 0.5` sums both client channels into
   slave channel 0. Confirmed by ear as well: content in both channels is audible.
   A third file, `~/.config/systemd/user/pipewire.service.d/10-omnibook-wait-for-card.conf`,
   holds PipeWire's start until `/proc/asound/card1/pcm2p` exists, because on the 14:04 boot
   `pipewire.service` started at monotonic 20.88 and card 1 registered at 22.65 — 1.8 s later,
   which with `nofail` would mean no speaker sink until something restarted PipeWire.
3. **`~/.local/bin/omnibook-speaker-mixer`** + `omnibook-speaker-mixer.service` (user, enabled)
   restores the amp mixer state from `~/.config/omnibook/speaker-asound.state` at session
   start. It waits up to 60 s for a control matching `Spk` to exist, because the codec
   components do not register controls until the card binds ~22 s into boot. It is ordered
   **`After=pipewire.service wireplumber.service`**, not before: session 7 watched all four
   DAPM pin switches get turned **off** across a `pipewire`+`wireplumber` restart, which
   silences the speakers while leaving the amps `Attached` and the volumes at 200. Restoring
   before the audio stack starts loses that race. Root-free by
   design: `alsactl --file` writes under `$HOME`, never `/var/lib/alsa/asound.state`, so the
   system `alsa-restore.service` is untouched. Verified by clobbering the pins and volumes and
   restarting the unit.

**Controls that matter**, and only these four exist — the dead amps register none:
`tas2783-2 Speaker Volume`, `tas2783-4 Speaker Volume` (0-200, 200 = 0 dB), and the DAPM pin
switches `Right Spk Switch` / `Right Spk2 Switch`. `amixer`'s **simple** mixer cannot see any
of them (`amixer sset` fails with "Unable to find simple control"); use
`amixer -c 1 cset numid=N` or `cset name='...'`.

### 6.1 The UCM overlay — installed, inert, and now explained

**Status, session 8: the overlay builds, parses, and `alsaucm -c hw:1 list _devices/HiFi`
reports a 7th device `Speaker` — but PipeWire's ACP layer builds no `HiFi` profile for this
card at all.** `pactl list cards` offers only `off` and `pro-audio`, `ALSA_CONFIG_UCM2` is
verified present in both the `pipewire` and `wireplumber` process environments, and the active
profile sits at `off`. So none of the UCM work below reaches the speakers.

**Session 7 wrote that this was unexplained and made it RANK 1. It is now explained, and the
two conclusions session 7 drew from it were both wrong: the overlay was NOT harmless — it was
what silenced the speakers at every boot (§ 6.2) — and ACP is NOT "the thing to fix", because
building the profile would put a second opener on `hw:1,2`.**

The chain, every link read in the shipped source and re-read by a second reviewer:

1. `ucm/sof-soundwire/tas2783.conf` sets `PlaybackChannels 1`. That sets
   `m->channel_map.channels = 1`, hence `exact_channels = true` (`alsa-ucm.c:2408`), hence
   `pa_alsa_open_by_device_string()` calls `snd_pcm_hw_params_set_channels(pcm, hwparams, 1)`
   with **no `_near` fallback** (`alsa-util.c:297`).
2. `hw:1,2` is fixed at two channels. Read straight out of the loaded topology
   `sof-sdca-2amp-id2.tplg`: the `Speaker` PCM's playback `stream_caps` has
   **`channels_min = channels_max = 2`**, rates mask `0x80` (48 kHz only). So the refinement is
   rejected inside `snd_pcm_hw_refine`. *(This closed session 7's "residual uncertainty"
   without opening the PCM — no listening test and no reboot were needed for it.)*
3. The retry that should rescue it wraps the name as `plug:SLAVE='%s'` (`alsa-util.c:754`)
   **without stripping alsa-lib's UCM alib prefix**, so it asks for
   `plug:SLAVE='_ucm0001.hw:sofsoundwire,2'` and dies `-ENOENT`. ACP only strips that prefix
   later, in `init_device()` (`acp.c:275-282`), which runs after probing.
4. `Speaker` is **first** in `p->output_mappings` (alsa-lib lists it last; `ucm_get_devices()`
   inserts with `PA_LLIST_PREPEND`, reversing the order), and `ucm_probe_profile_set()`
   **breaks the whole profile on the first mapping that fails** (`alsa-ucm.c:2589-2595`).
   One dropped mapping therefore drops the single `HiFi` profile, leaving `off` + `pro-audio`.

**`PlaybackChannels 1` is therefore load-bearing by accident, and must stay 1 for now.** If a
`HiFi` profile appeared, WirePlumber would move the card off profile `off` and ACP would open
`hw:1,2` for the Speaker port **while the direct node in
`50-omnibook-laptop-speaker.conf` also holds it** through `omnibook_spk` — two openers of the
one substream, which is exactly the condition that wedged this PCM in session 7 and is
recoverable only by an attended reboot. Fixing this properly means first deciding which of the
two owns the PCM, and the direct node is the one that does the L+R → channel 0 summing the
surviving amps need. The long comment on `PlaybackChannels` in the file says all of this.

Three things ruled out along the way, so nobody re-checks them: the failing
`exec '/bin/rm -rf /var/lib/alsa/card1.conf.d'` is a **`FixedBootSequence`** reachable only
via `_fboot`, which `alsactl` runs and `libspa-alsa.so` does not — it never touches PipeWire's
path, and it does not abort `alsactl restore` either (measured: the restore works, pins flip
`off`→`on`, with that error printed). The card-name lookup is fine (`<<<SplitPCM=1>>>hw:1`
resolves; `alsaucm -c "<<<SplitPCM=1>>>hw:1" list _devices/HiFi` exits 0 with all 7). And
`pro-audio` is **not** a fallback signal — `add_pro_profile()` is called unconditionally
(`acp.c:541`) and coexists with UCM.

**Two upstream bugs fall out of this and are worth filing** (neither is ours to work around):
`pa_alsa_open_by_device_string()` should strip `ucm->alib_prefix` before building
`plug:SLAVE='%s'`; and `ucm_probe_profile_set()` should drop the failing *mapping* rather than
the whole profile.

**What a working HiFi profile would actually buy is integration, not sound**: the speakers
become a card port with jack-driven availability (auto-mute when headphones are plugged), a
proper volume element, and profile/port switching, instead of an always-present standalone
node that never yields to headphones. Worth wanting eventually; not worth a wedged PCM now.

Three corrections session 7 had to make before the overlay was even self-consistent:

- `amps_up()` required **all** TAS2783 on the bus to be Attached and non-error. With the
  endpoint filter installed two are permanently UNATTACHED *and the speakers work*, so the
  gate would have stayed shut forever. It now requires ≥1 healthy amp **and** a Speaker PCM on
  the card — the honest test, since with every amp lost `sof_sdw.c:930` drops the dailink and
  there is no Speaker PCM at all.
- The codec-identity probe named only `tas2783-1 Speaker Volume`. `tas2783-1` is one of the
  amps that dies on every boot and registers no controls, so the probe found nothing and the
  Speaker device silently never appeared. It now tries all four prefixes.
- The ctl-remap folded amps 1,3 into virtual channel 0 and 2,4 into channel 1. With only 2 and
  4 surviving, channel 0 mapped to nothing. Every present amp is now folded into **both**
  virtual channels, matching the fact that all survivors sit on stream channel 0.

Backups of all three are in `backups/session7/`. **Do not leave `.bak-*` files inside `ucm/`** —
`ucm-overlay build` treats every file in that tree as an override and will farm them in.

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

**Session 7: it IS enabled now** (`ucm-overlay enable`, env file at
`~/.config/environment.d/60-omnibook-ucm.conf`) — and, per § 6.1's opening, currently inert
because ACP builds no HiFi profile. The original reasoning, which still governs the gate: A Speaker device that UCM offers with no amplifier
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

### 6.2 The silent boot — our own UCM overlay was muting the amps. FIXED, session 8.

**Symptom.** The 15:18 boot came up with everything right except the sound: both survivors
`Attached`, Speaker PCM at `hw:1,2`, "Laptop Speakers" sink present and clean in the journal —
and **all four DAPM pin switches reading `off`**. `omnibook-speaker-mixer.service` had run,
exited 0, printed no partial-restore warning, and its state file carries `value true` for all
four. The pins were set, then cleared.

**Cause, and it is ours.** `/sof-soundwire/HiFi.conf`'s `EnableSequence` opens with
`disdevall ""`. alsa-lib's `run_device_all_sequence()` (`ucm/main.c:712-736`, dispatched at
`:912-916`) runs the **`DisableSequence` of every device in the verb, unconditionally** —
enabled or not — whenever the verb is set. The overlay's `Speaker` device carried
`cset "name='${var:__Pin} Switch' 0"` for all four pins. ACP sets the verb during card
creation (`pa_alsa_ucm_get_verb`, `alsa-ucm.c:1129`; again from `add_pro_profile`,
`acp.c:346` — **twice** per card creation, not three times: `set_verb_user`,
`ucm_main.c:2830-2841`, short-circuits when the verb is already active).

In a working profile this is harmless — `disdevall` puts the card in a known-off state and
ACP then enables the device it wants, whose `EnableSequence` turns the pins back on. Here the
`HiFi` profile is thrown away before anything is ever enabled (§ 6.1), so **the disable is the
only half that ever runs.**

**Why it appeared on this boot and not on 14:04 — two of our own fixes collided.**

| monotonic | event |
|---|---|
| 16.177 | `pipewire.service` starts; `10-omnibook-wait-for-card.conf`'s `ExecStartPre` begins polling |
| 19.116 | card 1 registers (`device.plugged.usec = 19116140`) |
| 19.121 | card 1's PCMs appear; `ExecStartPre`'s predicate goes true |
| 19.190 | `pipewire` active — **`ExecStartPre` blocked 3.01 s** |
| 19.192 | `omnibook-speaker-mixer.service` starts (`After=pipewire wireplumber` is satisfied) |
| 19.219 | mixer finished — **pins written `true`** |
| ~19.36 | ACP creates the card, sets the verb, `disdevall` runs — **pins cleared** |

On the 14:04 boot PipeWire started at 20.88 and card 1 only registered at 22.65, so the mixer
restore (which polls for the controls) necessarily ran *after* ACP had already claimed the
card, and the pins survived. **`10-omnibook-wait-for-card.conf`, which fixed the missing sink,
inverted the ordering that had been accidentally protecting the pins.** And the overlay only
became able to do this in session 7: `~/.config/environment.d/60-omnibook-ucm.conf` was created
at 14:24:06, *after* the 14:04 boot's ACP card creation. Stock `sof-soundwire` UCM has no
Speaker device, so no pin `cset` exists — this failure mode did not exist before we built it.
It is also the mechanism behind § 6.0's "session 7 watched all four pins go off across a
`pipewire`+`wireplumber` restart", which was recorded as an unexplained observation.

**Fix.** The `DisableSequence` is gone from `ucm/sof-soundwire/tas2783.conf`; the
`EnableSequence` stays. Dropping it costs nothing while the profile is never built, and stays
correct if it ever is: enabling `Speaker` still turns the pins on, and leaving them on when it
is disabled is what this machine wants anyway — the speakers are driven by the direct PipeWire
node, not by this device. Rebuilt with `ucm-overlay build`, which touches no services.

**Demonstrated A/B, live, without a reboot** — `alsaucm -c hw:1 set _verb HiFi` is exactly what
ACP does at card creation:

| overlay | pins before | pins after | other controls changed |
|---|---|---|---|
| new (fixed) | `on on on on` | `on on on on` | **none at all** (full `amixer contents` diff empty) |
| old (positive control, from a scratch copy of the tree) | `on on on on` | **`off off off off`** | — |

**`disable` was deliberately not used.** `ucm-overlay disable` — and `enable` — run
`systemctl --user restart wireplumber`, and restarting the audio stack while the speaker node
holds the PCM is what wedged it in session 7 (§ 4). Patching the file and rebuilding needs no
restart at all; the fix lands at the next card creation.

**Side finding, fixed at the same time: `ucm-overlay check` was silently useless.** It compared
`devices()` (explicitly `ALSA_CONFIG_UCM2="$TREE"`) against a bare `alsaucm` for the "stock"
side — but once the overlay is enabled, `ALSA_CONFIG_UCM2` is in the user manager's
environment and therefore in every shell that runs the script, so *both* sides read the
overlay. It reported no gains, and, far worse, its one real safety assertion — "the overlay
must not LOSE a stock device" — was comparing the tree against itself and **could never
fire**. `stock_devices()` now uses `env -u ALSA_CONFIG_UCM2`; `check` reports `gains: Speaker`
again.

**Still unverified:** that the pins come up `on` unaided on the *next* boot. The A/B proves the
mechanism and the fix, but the boot path itself has not been re-run. Check it first thing:

```bash
for n in 14 15 16 17; do amixer -c 1 cget numid=$n | sed -n 's/^  : values=//p'; done
```

Four `on` and no manual `cset` needed means this is closed.

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
| `sdw-utils-build/` | v7.1.9 `sound/soc/sdw_utils/` + `omnibook-filter-unattached-amps.patch` (drop SmartAmp endpoints whose peripheral is off the bus). **INSTALLED AND WORKING since the 08-27 14:04 boot — this is what makes the speakers play.** `filter_unattached_amps=Y` — vermagic, `depends:` and the 58-symbol export surface all identical to stock; only new externals are `param_ops_bool` and `wait_for_completion_timeout`, both from vmlinux. `sitting.sh install|revert|verify` |
| `cadence-build/` | v7.1.9 `cadence_master.{c,h}` + the rescan re-arm patch, built, **not installed** |
| `sof-sdw-order/` | `src/` — a self-contained v7.1.9 tree for the two SOF modules, plus `sof-sdw-start-after-fw-boot.patch`. Builds warning-free; `depends:` identical to stock. **Not installed** |
| `acpi/` | where to put the DSDT/SSDT dump the next root window should take |
| `ucm/`, `ucm2/`, `ucm-overlay`, `ucm-test.sh` | the UCM last mile (§ 6) |
| `sdw-trace.sh` | dyndbg arm/disarm + trace report. **Armed.** |
| `boot-20260827-1200/` | the preserved evidence of the two-amp boot: `kernel.txt`, `sysfs.txt`, `pcm.txt`, `recorder.txt` |
| `boot-20260827-1404/` | **the boot that made sound**: `kernel.txt` (the RANK 2 trace, § 2.6) |
| `backups/session7/` | pre-session-7 `ucm-overlay`, `sof-soundwire.conf`, `codecs/tas2783/init.conf` |
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

---

## 10. Session 9 (2026-08-28) — observations taken while distilling this into a repo

No changes were made to the running system in this session. These are read-only
observations from the 15:57 boot, taken while the fix was being packaged.

### 10.1 The card index is not stable, and it broke the speakers. **NEW.**

The 15:57 boot came up with **no USB audio device attached**, so `sof-soundwire` registered
as **card 0** rather than card 1. Every hardcoded `hw:1` in the userspace half then pointed
at nothing:

| file | hardcoded |
|---|---|
| `~/.asoundrc` | `slave { pcm "hw:1,2" }` |
| PipeWire wait drop-in | `[ -e /proc/asound/card1/pcm2p ]` |
| the mixer script | `_SPEAKER_CARD:=1` |
| the UCM overlay | `alsaucm -c hw:1`, `/proc/asound/card1/pcm2p/info` |

Result: `pactl list short sinks` showed only `auto_null`. The kernel half was **completely
healthy** — four `assuming SmartAmp`, four `Found Smart Amp`, all firmware names resolving,
the endpoint filter active, and a `Speaker` PCM present at `hw:0,2`.

This is a silent, total failure of the userspace half triggered by nothing more than
unplugging a USB headset before a reboot. **Every path in this repo now addresses the card
by ID** (`hw:CARD=sofsoundwire`, `amixer -c sofsoundwire`, `/proc/asound/sofsoundwire/`),
which is a symlink the kernel maintains and which does not move. Verified live:
`/proc/asound/sofsoundwire -> card0`, `alsaucm -c hw:sofsoundwire` and
`amixer -c sofsoundwire` all resolve correctly.

The live configuration under `$HOME` still carries the old hardcoded values — it was not
changed in this session.

### 10.2 The DAPM pins come up `on` unaided. **§ 6.2's open item is CLOSED.**

§ 6.2 ended with "still unverified: that the pins come up `on` on the *next* boot". They do:

```
numid=14,iface=MIXER,name='Left Spk Switch'    on
numid=15,iface=MIXER,name='Right Spk Switch'   on
numid=16,iface=MIXER,name='Left Spk2 Switch'   on
numid=17,iface=MIXER,name='Right Spk2 Switch'  on
```

No manual `cset` was needed. The `DisableSequence` removal is confirmed across a reboot.

### 10.3 Amp `:9` is in a continuous firmware-download retry storm. **NEW, and unexplained.**

`sdw:0:2:0102:0000:01:9` is not simply dead this boot. It is **cycling**: attaching,
attempting its firmware download, failing, detaching, and retrying — continuously, for the
whole uptime.

```
52996  FW download failed        (this boot, still climbing)
51372    sdw:0:2:...:9  -61      (-ENODATA, SDW_CMD_IGNORED)
 1798    sdw:0:2:...:9  -5       (-EIO)
    2    sdw:0:2:...:c  -5
```

First at 15:58:01.848, most recent at 16:17:40.372 — **~20 minutes and ~44 lines per
second**, with no sign of stopping. Two consecutive reads of
`/sys/bus/soundwire/devices/sdw:0:2:0102:0000:01:9/status` minutes apart returned
`UNATTACHED` and then `Attached`.

Three things follow:

1. **It corroborates § 2.7's central finding.** The dying amplifiers are *marginal, not
   absent* — detection keeps succeeding and register I/O keeps failing. This is that
   signature, sustained over twenty minutes instead of caught in a boot window, and it is
   the strongest single piece of evidence for the upstream report (§ 9).
2. **It is probably making things worse in a way § 4 already predicted.**
   `tas_io_init()` blocks up to `TIMEOUT_FW_DL_MS` (3000 ms) in `wait_event_timeout()`
   while holding `cdns->status_update_lock`, stalling every other peripheral on link 2 —
   which is where the surviving `:c` also lives. A retry storm on `:9` is therefore not
   harmless to `:c`. Whether this, rather than (or as well as) § 10.1, is why this boot has
   no working speaker sink has **not** been determined.
3. **`cfg-amp:2` this boot**, versus `cfg-amp:4` on the boots recorded in § 2. The endpoint
   filter logged 5 endpoint drops.

Never observed on any earlier boot in this record. What differs about the 15:57 boot beyond
the missing USB device is not known. **Do not treat this as the steady state** until it has
been seen a second time.

### 10.4 Two script bugs found and fixed while porting

- **The boot-verdict recorder produced word salad.** Its pattern list was built with line
  continuations inside a single-quoted `for` list, so the patterns split on whitespace and
  every recorded boot verdict came out as a meaningless two-column dump — including the
  preserved `boot-20260827-1200/recorder.txt` in `archive/`. Rewritten with an array.
- **The trace tool's `report` had the reference machine's hostname baked into its `sed`.** That
  both leaked the hostname and silently did nothing on any other machine. It now strips the
  host field generically.

Also: there is **no `/proc/asound/card*/components`** on this kernel — every script that
read it was reading nothing. The components string lives in the ALSA card info and
`amixer -c <card> info` reads it without a PipeWire session.

### 10.5 What is still outstanding

- **PIN THE KERNEL** (§ 5 RANK 1 item 1). Still not done. `/etc/pacman.conf` has no
  `IgnorePkg`. See [porting.md](porting.md).
- **Dump the ACPI tables** (§ 5 RANK 1 item 2). `archive/evidence/acpi/` is still empty.
- **File upstream** (§ 5 RANK 1 item 3). Nothing filed. See [upstream.md](upstream.md).
- **Explain § 10.3.** New.
- **Decide whether to move the live `$HOME` configuration onto the card-ID paths** in
  § 10.1. Not done in this session; it needs a listening test with someone at the machine.
