# Laptop speakers (TAS2783 SoundWire) — persistent state

**Last updated: 2026-08-27, session 5.** This file is the authoritative, reboot-surviving
record. It lives outside `/tmp` on purpose (`/tmp` is tmpfs here). Read it first.
Session 4's version is kept as `STATE.md.bak-session4`; **large parts of it are now known
to be wrong** — see § 2.0.

Companion documents in this directory:
- `standalone/README.md` — the portable fix for a *new* device.
- `sdw-trace.sh` — `arm`/`disarm` dyndbg for the SoundWire stack, `report` the enumeration
  trace, `state` the whole stack. The working tool. **Currently ARMED.**
- `ucm-overlay` — the ALSA UCM last mile, root-free. See § 6.
- `cadence-build/` — an out-of-tree `soundwire-cadence.ko` with the rescan re-arm patch.
- `sdca-build/` — the out-of-tree `snd-soc-sdca.ko` that gets past the BIOS defect.

---

## 0. Where this stands in one paragraph

Defects 1 and 2 are fixed and stay fixed. **Defect 3's diagnosis was wrong** — the premise
it was built on (SoundWire interrupts gated on the SOF DSP boot) is false on Panther Lake,
verified in the shipped source — but *whether its workaround helps or hurts is not
established either way*, so it is left in place. Defect 4 — the amplifiers attach, then
leave the bus and never come back — has been **observed properly exactly once** (§ 2.4),
and the single best predictor is that it happens ~92 ms before the DSP firmware reports
ready. Everything that can be done without root is done, including the whole UCM last mile,
which is staged and self-arming. **What remains needs one attended sitting at the machine**
— root needs the FIDO2 key and so does the reboot after it (§ 4) — and the first thing to
do there is not a fix but a measurement (§ 5).

---

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
  times in the whole boot, once per link. Links 1 and 2 read `runtime_status=active` with
  `runtime_suspended_time=0` to this minute — they have **never** runtime-suspended. The
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

**The measurement that would settle it has never been taken.**
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
| 0 | 08-27 05:09 | yes | yes | yes | **full** | **the only boot where the detach itself was captured**: all four NPRESENT at 46.2128, 93 ms before `Booted`, never returning |

Read it as: **exactly one boot on record actually observed the failure.** Every other row
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
  forever, which is why **no runtime PM cycle can ever fire on those links** — the one
  mechanism (`intel_resume_runtime` -> `sdw_intel_start_bus_after_reset()`) that would do a
  full re-enumeration is unreachable. Contrast link 3, which suspends normally.
- **`power/control` offers no "force suspend".** `on` is `pm_runtime_forbid()` (a get),
  `auto` is `pm_runtime_allow()` (the matching put); the pair returns you where you
  started. There is no sysfs lever that drops a held reference.
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

## 5. >>> NEXT STEP <<< — one attended sitting

**Read the FIDO2 trap in § 4 first.** Root needs the key, *and so does the reboot*: this is
one sitting at the machine, not three separable steps.

### The safe set — do this, it cannot cost you anything

```bash
sudo ~/.local/share/omnibook-speaker-fix/standalone/omnibook-speaker-fix install
sudo reboot                     # be at the console: FIDO2 unlocks root
~/.local/share/omnibook-speaker-fix/standalone/omnibook-speaker-fix verify
cat /var/log/omnibook-speaker/latest.txt
```

`install` is idempotent, touches no module the audio stack depends on, and does four
things: the firmware symlinks (defect 2), the patched SDCA module (defect 1) — both
already in place, so both are no-ops — plus:

3. **`trace`** — rewrites `/etc/modprobe.d/omnibook-sdw-debug.conf` with the same SoundWire
   dyndbg *plus* `options snd_sof dyndbg="file loader.c +p"`. That adds two lines per boot,
   `booting DSP firmware` and `firmware boot complete`, and they are **the whole point**:
   `snd_sof_dsp_post_fw_run()` runs between `firmware boot complete` and
   `Booted firmware version`, so those two timestamps put the detach inside the DSP boot or
   after it. Nobody has ever measured that.
4. **`recorder`** — a one-screen verdict per boot in `/var/log/omnibook-speaker/`
   (`latest.txt` is a symlink to the newest), written 30 s after `sound.target` by a
   read-only oneshot. So a boot that happens when nobody is watching still leaves a record.

**The one thing to read afterwards**, in the trace report:

```
booting DSP firmware
firmware boot complete          <- snd_sof_dsp_post_fw_run() runs here
Slave status change: 0x110      <- the detach. WHICH SIDE OF THE LINE ABOVE IS IT ON?
Booted firmware version
```

- Detach **before** `firmware boot complete` → it is inside the firmware boot, and the
  `sof-order` experiment below is aimed at the right place.
- Detach **after** `firmware boot complete` → `post_fw_run` is *also* after it, so
  `sof-order` would start the links straight into the disturbance and is the wrong fix.
- No `0x110` at all, all four `Attached` → done; the user unit in § 6 turns the speaker
  sink on by itself.

### The two experiments — priced, and neither is recommended blind

Both are built, reviewed and staged. Neither is in `install`. Each needs its own reboot,
which means its own attended sitting, and each can cost the whole card until reverted.

| | `cadence` | `sof-order` |
|---|---|---|
| what | re-arm the one-shot Cadence rescan: bounded retry, 20 x 250 ms per bus start, plus an arming point where the loss is observed | move `hda_sdw_startup()` out of `hda_dsp_probe()` into `post_fw_run` on ACE 3.0 |
| modules | 1 (`soundwire-cadence.ko`, one .c file) | 2 (`snd-sof-intel-hda-generic`, `snd-sof-pci-intel-ptl`) |
| the objection | the amps do not re-report as device 0 at all after the loss, so a rescan probably finds nothing. `cdns_update_slave_status_work()` already re-read `CDNS_MCP_SLAVE_STAT` at that moment with dyndbg armed and never printed `Device0 detected after clearing status` | `post_fw_run` is called **before** `Booted firmware version`, i.e. within a few ms of the observed detach — it may land inside the very window it is meant to avoid. It also disables the dspless escape hatch (`snd_sof.sof_debug=0x8000` skips `snd_sof_run_firmware()`, so `post_fw_run` never runs and no link is started) |
| the argument for | it is the right shape for the resume path regardless, and #5824 reports the same symptom on an AMD manager, i.e. at the shared Cadence layer | upstream moved the startup earlier only as an optimisation — commit `67bde2e8c0e4` (Bossart, 2024-02-13), *"no dependencies on the DSP enablement"* — so `post_fw_run` ordering is what LNL shipped until Feb 2024. It has never been exercised on ACE 3.0 |
| blast radius | SoundWire audio only | **the whole card**: a failing `snd_sof_run_firmware()` aborts the SOF probe before the card is registered, taking the headset jack, HDMI 1-3, deepbuffer and mics. The build here makes `hda_sdw_startup()`'s failure non-fatal specifically to avoid that |

`sof-order` prompts for confirmation and prints the blast radius; set `OMNIBOOK_SPK_YES=1`
to skip the prompt. Revert for either: `omnibook-speaker-fix revert` (restores every
`.stock` module) + reboot.

### And while root is available, take the two readings that are otherwise unreachable

```bash
sudo cp /sys/firmware/acpi/tables/{DSDT,SSDT*} ~/.local/share/omnibook-speaker-fix/acpi/
sudo cat /sys/kernel/debug/soundwire/master-0-*/intel-sdw/intel-registers   # do this LAST
```
The DSDT settles whether the four amps share a power resource. The debugfs read is a live
register read that will `pm_runtime_get`/`put` the links, which destroys the
"links 1 and 2 have never suspended" datum — so take it last, after everything else.

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
no root) runs `ucm-overlay auto` at every session start: it enables the overlay only when
**every** TAS2783 on the bus reports `Attached`, and disables it again if they go away. So
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
| `cadence-build/` | v7.1.9 `cadence_master.{c,h}` + the rescan re-arm patch, built, **not installed** |
| `sof-sdw-order/` | `src/` — a self-contained v7.1.9 tree for the two SOF modules, plus `sof-sdw-start-after-fw-boot.patch`. Builds warning-free; `depends:` identical to stock. **Not installed** |
| `acpi/` | where to put the DSDT/SSDT dump the next root window should take |
| `ucm/`, `ucm2/`, `ucm-overlay`, `ucm-test.sh` | the UCM last mile (§ 6) |
| `sdw-trace.sh` | dyndbg arm/disarm + trace report. **Armed.** |
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
bus.* A different manager with the same symptom is the strongest argument that the fix
belongs at the shared Cadence layer rather than in Intel/SOF code.

Three things worth sending upstream once the trace confirms them:
1. `.component_name = "tas2783"` in `codec_info_list[]` — a one-line fix for the missing
   `spk:` token, plus the matching `alsa-ucm-conf` files from `ucm/`.
2. The Cadence rescan re-arm (`cadence-build/sdw-cadence-rearm-attach-rescan.patch`),
   attached to #5877 and cross-referenced to #5824.
3. `tas_io_init()` blocking up to 3 s in `wait_event_timeout()` while holding
   `cdns->status_update_lock`, which stalls every other peripheral on the same link. That
   is a bug regardless of whether it is *this* bug.

#5760 was resolved by a BIOS emitting `mipi-sdca-control-dc-value`, which would retire the
OOT SDCA module entirely — worth re-checking HP for a BIOS newer than Insyde F.06.
