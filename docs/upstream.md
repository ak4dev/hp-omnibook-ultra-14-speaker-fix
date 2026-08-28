# Upstream

## Existing trackers — all open, none answered

| Tracker | Board |
|---|---|
| thesofproject/linux **#5877** | this exact board (`8EB4`) |
| thesofproject/linux **#5802** | this exact board |
| thesofproject/linux **#5816** | sibling HP chassis |
| thesofproject/linux **#5760** | sibling HP chassis — **resolved by a BIOS that emits `mipi-sdca-control-dc-value`** |
| bugzilla.kernel.org **#221782** | same board, same BIOS F.06 |
| Launchpad **#2143870** | — |
| thesofproject/linux **#5824** | ASUS ProArt PX13, AMD manager, two TAS2783 on one link |

**#5760 matters**: a corrected BIOS retires the out-of-tree SDCA module entirely. Worth
re-checking HP for firmware newer than Insyde F.06.

## What to file, and how not to get it dismissed

Nothing has been filed from this work yet. A new issue on thesofproject/linux, cross-linked
into **#5877** and bugzilla **#221782**.

> **Do not frame it via #5824.** That AMD case was root-caused to `amd_manager.c:287`, the
> peripheral never leaves the bus there, and unbind/rebind recovers it. Framing this that way
> gets it dismissed.

**Lead with what nobody has posted:**

1. **The marginal-link signature.** The dying amplifiers are *marginal, not absent*. One
   returned its correct DEVID **31 times**, took a device number **24 times**, then failed
   its first register write **every time** with parity errors — and seven DEVID reads came
   back bit-corrupted, two of which manufactured phantom devices. **Detection is not the
   failure; register I/O is.**
2. **The timing pin.** The detach falls **−2.98 ± 0.61 ms** relative to
   `firmware boot complete`, across three boots and two different DSP-boot durations, and
   66 ms *after* the code-loader DMA has stopped. The code loader is exonerated.
3. **The completed-s2idle negative result.** The strongest reset the kernel has — controller
   to D3, all links down, Cadence soft reset, bus `HW_RST`, full device-0 re-enumeration, no
   DSP running — does not bring them back.
4. **The RT712 negative control** on the same shim: the headset codec on link 3 is unaffected.
5. An offer to test pre-release patches on an instrumented box.

**Where the fix belongs.** #5824 is a *different SoundWire manager with the same symptom*,
which is the strongest argument that the fix belongs **below** Intel/SOF — but **not** at the
Cadence layer: AMD's manager does not use it
(`modinfo -F depends soundwire-amd` → `soundwire-bus,soundwire-generic-allocation,snd-pcm,snd-soc-core`).
The only code shared with an AMD box is `soundwire-bus` (`bus.c`/`slave.c`), the TAS2783
peripheral driver, or the silicon itself. **Frame it as the shared bus layer**, and note that
this board reproduced #5824's exact asymmetry — the second-enumerated amp on each link died,
the first survived and completed its download.

Intel's maintainer has said HP and TI are preparing kernel patches for a second, non-BIOS
defect on this chassis. That is the realistic route to the right-hand speakers.

## Patches worth sending

1. **The Cadence rescan re-arm** — `kernel/cadence/`, attached to #5877 and cross-referenced
   to #5824. Send the *corrected* rationale from [experiments.md](experiments.md), not the
   original one: its mechanism has been measured running for free and returning nothing on
   this board, and it carries a real cost on every bus start.
2. **`tas_io_init()` blocks up to 3 s** in `wait_event_timeout()` while holding
   `cdns->status_update_lock`, stalling every other peripheral on the same link. That is a
   bug regardless of whether it is *this* bug.
3. **The `alsa-ucm-conf` files** in `userspace/ucm/` are worth sending to alsa-project — there
   is no `tas2783` profile upstream at all. Note the `PlaybackChannels` caveat in
   [ucm.md](ucm.md) before proposing them as-is.

## Already upstream — do not re-file

- `.component_name = "tas2783"` in `codec_info_list[]`. Mainline `soc_sdw_utils.c` now carries
  both `.is_amp = true` and `.component_name = "tas2783"`.
- The firmware-name fallback: `e26bb459d0f3` ("ASoC: tas2783: Update loaded firmware names to
  linux-firmware 20260519"), in 7.2.

## Not a kernel bug

Defect 1 is a **BIOS bug** and belongs to HP: the DSDT omits `mipi-sdca-control-dc-value`
from each amplifier's `mipi-sdca-control-0x5-subproperties`. Upstream has deliberately
declined to accept the non-DC form, and #5760 shows the vendor fix is achievable.
