# Laptop speakers (TAS2783 SoundWire) — persistent state

**Last updated: 2026-08-26, session 3.** This file is the authoritative, reboot-surviving
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

## 2. Three stacked, independent defects

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

### Defect 3 — the firmware download races the audio bring-up. **ROOT-CAUSED, NOT YET FIXED.**
This is the current wall, and it only became visible once defects 1 and 2 were cleared.

At cold boot the amp firmware download fails:
```
15:40:11.909841  slave-tas2783 sdw:0:1:...:d: FW download failed: -61
15:40:11.910247  slave-tas2783 sdw:0:1:...:d: fw with no files
15:40:11.910453  slave-tas2783 sdw:0:2:...:c: FW download failed: -61
15:40:11.911271  soundwire sdw-master-0-1/2: trf on Slave 1 failed:-5 write addr 8800
15:40:11.912728  slave-tas2783 sdw:0:1:...:a: SDW_SCP_BUS_CLOCK_BASE write failed:-61
15:40:11.912921  slave-tas2783 sdw:0:1:...:a: Slave 2 initialization failed: -61
15:40:12.001825  sof-audio-pci-intel-ptl: Booted firmware version: 2.14.1.1
15:40:40.162067  slave-tas2783 ...:a: error playback without fw download
                 -> ASoC error (-22) at snd_soc_dai_hw_params on tas2783-codec
                 -> SDW1-Playback-SmartAmp -> Speaker
```

**Mechanism, established:**
- `-61` is `-ENODATA`, which the SoundWire core returns for `SDW_CMD_IGNORED` — the
  peripheral did not ACK (`drivers/soundwire/bus.c:224-225`, v7.1.9).
- **`fw with no files` is a CONSEQUENCE, not a parsing bug.** `tas2783_fw_ready()` breaks
  out of its per-file loop on the first failed `sdw_nwrite_no_pm()`, leaving `cur_file == 0`.
  The blob is intact: `8EB4-1-0xA.bin` is 40746 bytes, its header size field reads
  0x9F2A = 40746 so `hdr->size == img_sz` passes, DDC name
  `HP_Graham_alpha10_251014_Xover_RNS_EQ`, and it parses to **52 files** (fid 0..51).
- `tas_io_init()` runs from the SoundWire *attach* callback. On Intel ACE 2.0+ (Panther Lake
  is ACE 3.0) the links are started early, in `hda_dsp_probe()`
  (`sound/soc/sof/intel/hda.c:911-918`), but **SoundWire interrupts are only enabled in
  `hda_dsp_post_fw_run()` (`hda.c:454`), after the DSP firmware boots.** The download at
  15:40:11.909 therefore ran ~92 ms *before* `Booted firmware version` at 15:40:12.0018.
- `TAS2783_SW_RESET` is **not** a SoundWire reset and causes no re-enumeration — upstream
  commit `b627da43035744` says so explicitly. Do not re-tread that theory.

**THE DECISIVE EXPERIMENT (2026-08-26 15:55, run as root):**
`sdw_bus_probe()` calls `drv->ops->update_status(slave, slave->status)` at the end of probe
(`drivers/soundwire/bus_type.c:148`), so unbinding and re-binding an *attached* peripheral
re-enters `tas_update_status()` → `tas_io_init()` and redoes the download. Done on a
fully-booted system via `probe-fw-download.sh`:

```
sdw:0:1:...:d  ->  52/52 files written, "No calibration data in UEFI.", "probe complete"
sdw:0:2:...:c  ->  52/52 files written, "No calibration data in UEFI.", "probe complete"
ZERO SoundWire errors in the whole retry window.
```
First file: `v=0, fid=0, ver=1, len=32632, daddr=0xc60088`; second `len=6904, daddr=0x800108`;
then ~50 short register writes. Full log: `/tmp/tas2783-probe.log` (tmpfs — gone after reboot).

**Conclusion: the boot failure is purely an ordering race. The hardware, the blobs, the
symlinks and the patched SDCA module are all fine. The download works when retried after
the audio stack is up.**

Caveat on that run: the script's own "verdict" line said FAILED. That was a bug in the
script, not a result — `dmesg -w` prints the existing ring buffer before following, so the
grep matched the *boot* failures replayed into the log. Ignore the verdict line; read the
`fid=` lines.

Side effect of that experiment: card 1 was torn down and could not be rebuilt, because the
HDA HDMI codec cannot re-probe at runtime (`snd_hda_codec_intelhdmi ehdaudio0D2: HDMI:
failed to get afg sub nodes` → `hdac_hda_codec_probe: probe failed -22` →
`sof_sdw: ASoC: failed to instantiate card -22`). **This is an artifact of tearing down a
live card, unrelated to the amps.** A reboot restores it. It also rules out
"unbind/bind after boot" as the shipping fix.

---

## 3. Also known, not blockers

- **`:a` and `:9` (Slave 2 on each link) are UNATTACHED** and were never initialised; they
  failed in the *core* at `sdw_initialize_slave()` in the same ~92 ms window. `:d` and `:c`
  (Slave 1) are Attached. `sdw_initialize_slave()` is **not** gated on `slave->probed`
  (`bus.c:1980`), so this is core-level, not driver-level. It is very likely the same race —
  but unproven, and it matters: the failing playback DAI `SDW1-Playback-SmartAmp` is on
  **`:a`**, so fixing only `:d`/`:c` may not produce sound.
- **`sof-sdca-4amp-id2.tplg` being a 154-byte stub is a phantom concern.** `sdca-%damp` is
  built from `dai_link->num_cpus`, which counts SoundWire *links*, not amplifiers. Four amps
  on two links correctly request `sof-sdca-2amp-id2.tplg`, which is real and loads.
  `sof-topology-fix/` holds the upstream `[1-3]`→`[1-4]` gate fix anyway, for reporting.
- **UCM (was "defect 3", now the last mile).** `alsa-ucm-conf` has no `tas2783` profile, and
  `sof-soundwire/HiFi.conf` includes `${var:SpeakerCodecFile}.conf` unconditionally once the
  codec name is non-empty. PipeWire currently exposes **no Speaker sink** for card 1 (only
  Headphones + 3× HDMI) — expected. Model a new file on `rt1320.conf` in the same directory.
  Only actionable once the amps actually take firmware at boot.

---

## 4. >>> NEXT STEP <<<

Card 1 is currently **gone** (see the experiment side effect above). A reboot restores it.

After the reboot, in order:

1. Confirm the boot failure reproduces and defects 1+2 stay fixed:
   ```bash
   journalctl -k -b 0 | grep -iE "DisCo constant|Found Smart Amp|FW download|fw with no files|Direct firmware load|Booted firmware"
   aplay -l | grep -i speaker
   ```
   Expect: `assuming SmartAmp` ×4, `Found Smart Amp` ×4, a `Speaker` PCM, no
   `Direct firmware load` failure, and `FW download failed: -61` ×2.

2. Apply a defect-3 fix and re-test. Two candidates, cheapest first — `FIX.md` has both
   in full:
   - **(A) No-build: defer the module load.** Stop udev auto-loading
     `snd_soc_tas2783_sdw` at boot and load it from a systemd unit once the audio stack is
     up, so `sdw_bus_probe()` → `update_status()` → `tas_io_init()` runs on a live bus —
     exactly the state the successful experiment ran in. The card is built *once*, after
     the amps are ready, so the HDA-HDMI teardown problem cannot occur.
     **Open risk:** `sof_sdw` must *defer* rather than instantiate a card without the amps.
     It should — `soc_bind_dai_link()` returns `-EPROBE_DEFER` on a missing codec component —
     but this is the thing to watch in the log.
   - **(B) Kernel patch: retry the download.** Retry `sdw_nwrite_no_pm()` on `-ENODATA`
     with bounded backoff inside `tas2783_fw_ready()`. The ~92 ms window sits well inside
     the existing `TIMEOUT_FW_DL_MS` (3000 ms), so the retry has room. More robust and
     portable than (A), upstreamable, and the OOT build recipe already exists
     (`sdca-build/`) — but it is a second machine- and kernel-version-specific module.

3. If `:a`/`:9` still refuse to attach after the download succeeds, that is a separate
   problem and must be solved before there is sound, because the Speaker DAI runs through `:a`.

---

## 5. Safety and revert

Nothing here touches the boot path. `snd-soc-sdca` is a loadable module (zero hits in
`modules.builtin`), `CONFIG_MODULE_SIG_FORCE` unset, `sig_enforce=N`, lockdown `[none]`,
Secure Boot off. Worst case is no audio until the stock module is restored.

```bash
sudo bash ~/.local/share/omnibook-speaker-fix/apply-speaker-fix.sh --revert
```
restores `snd-soc-sdca.ko.zst.stock` and drops the firmware links.

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
| `probe-fw-download.sh` | live unbind/bind retry experiment (its "verdict" line is buggy — read the `fid=` lines) |
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

Relevant commits after v7.1 (none applied here):
`b627da43035744` drop stale regcache on uninitialized re-attach ·
`0d6b2d6f93a671` propagate regcache_sync() errors ·
`e26bb459d0f3da` firmware names for linux-firmware 20260519 (defect 2) ·
`ea9ff3b7bcfbcd` add back `sdw_show_ping_status()` ·
`ca1063ae03dcbf` + `ac6d4f298160be` new SoundWire enumeration helper.

Two people report sound from this patch class on sibling HP boards
(thesofproject/linux#5760, Launchpad #2143870); neither filed upstream.
