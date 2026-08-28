# The ALSA UCM overlay — installed, inert, and deliberately so

`alsa-ucm-conf` has no `tas2783` profile, so a card whose only amplifiers are TI TAS2783
parts gets no `Speaker` device and therefore no speaker sink. `bin/omnibook-ucm-overlay`
installs one, for one user, with no root: `$ALSA_CONFIG_UCM2` points at a **symlink farm**
of the stock tree with only the overridden files real, so an `alsa-ucm-conf` upgrade is
picked up without rebuilding.

**It works, and it is not what makes the speakers play.** The direct PipeWire node in
[userspace.md](userspace.md) is. Read this before enabling the overlay.

---

## Why ACP builds no HiFi profile — and why that is protective

`alsaucm -c hw:sofsoundwire list _devices/HiFi` reports a `Speaker` device. `pactl list
cards` still offers only `off` and `pro-audio`. The chain, read in the shipped source:

1. `ucm/sof-soundwire/tas2783.conf` sets **`PlaybackChannels 1`**. That sets
   `m->channel_map.channels = 1`, hence `exact_channels = true` (`alsa-ucm.c:2408`), hence
   `pa_alsa_open_by_device_string()` calls `snd_pcm_hw_params_set_channels(pcm, hwparams, 1)`
   with **no `_near` fallback** (`alsa-util.c:297`).
2. The Speaker PCM is **fixed at two channels** — read straight out of the loaded topology,
   whose playback `stream_caps` has `channels_min = channels_max = 2` and a rates mask of
   `0x80` (48 kHz only). So the refinement is rejected inside `snd_pcm_hw_refine`.
3. The retry that should rescue it wraps the name as `plug:SLAVE='%s'` (`alsa-util.c:754`)
   **without stripping alsa-lib's UCM alib prefix**, so it asks for
   `plug:SLAVE='_ucm0001.hw:sofsoundwire,2'` and dies `-ENOENT`. ACP only strips that prefix
   later, in `init_device()` (`acp.c:275-282`), which runs after probing.
4. `Speaker` is **first** in `p->output_mappings` (alsa-lib lists it last;
   `ucm_get_devices()` inserts with `PA_LLIST_PREPEND`, reversing the order), and
   `ucm_probe_profile_set()` **breaks the whole profile on the first mapping that fails**
   (`alsa-ucm.c:2589-2595`). One dropped mapping therefore drops the single `HiFi` profile,
   leaving `off` + `pro-audio`.

**`PlaybackChannels 1` is load-bearing by accident, and must stay 1 for now.** If a `HiFi`
profile appeared, WirePlumber would move the card off profile `off` and ACP would open the
Speaker PCM for the Speaker port **while the direct node also holds it** through
`omnibook_spk` — two openers of the one substream, which is exactly the condition that wedges
this PCM, recoverable only by a reboot ([traps.md](traps.md)).

Fixing this properly means first deciding which of the two owns the PCM. The direct node is
the one that does the L+R → channel 0 summing the surviving amps need.

---

## The silent boot — our own overlay was muting the amps

Worth reading even if you never enable the overlay, because the mechanism is general.

**Symptom.** A boot came up with everything right except the sound: both survivors
`Attached`, the Speaker PCM present, the "Laptop Speakers" sink present and clean in the
journal — and **all four DAPM pin switches reading `off`**. The mixer-restore unit had run,
exited 0, and its state file carried `value true` for all four. The pins were set, then
cleared.

**Cause.** `/sof-soundwire/HiFi.conf`'s `EnableSequence` opens with `disdevall ""`, and
alsa-lib's `run_device_all_sequence()` (`ucm/main.c:712-736`, dispatched at `:912-916`) runs
the **`DisableSequence` of every device in the verb, unconditionally** — enabled or not —
whenever the verb is set. The overlay's `Speaker` device carried
`cset "name='${var:__Pin} Switch' 0"` for all four pins. ACP sets the verb during card
creation (`pa_alsa_ucm_get_verb`, `alsa-ucm.c:1129`; again from `add_pro_profile`,
`acp.c:346` — twice per card creation).

In a working profile this is harmless: `disdevall` puts the card in a known-off state and
ACP then enables the device it wants, whose `EnableSequence` turns the pins back on. Here the
`HiFi` profile is thrown away before anything is ever enabled, so **the disable is the only
half that ever runs.**

**Why it appeared when it did — two fixes collided.** The `wait-for-card` PipeWire drop-in
made PipeWire start later, so the mixer restore (which polls for the controls) finished
*before* ACP claimed the card instead of after:

| monotonic | event |
|---|---|
| 16.177 | `pipewire.service` starts; the wait drop-in begins polling |
| 19.116 | the card registers |
| 19.121 | its PCMs appear; the predicate goes true |
| 19.190 | pipewire active — the drop-in blocked **3.01 s** |
| 19.192 | the mixer unit starts (`After=pipewire wireplumber` satisfied) |
| 19.219 | mixer finished — **pins written `true`** |
| ~19.36 | ACP creates the card, sets the verb, `disdevall` runs — **pins cleared** |

On the previous boot PipeWire started before the card registered, so the mixer restore
necessarily ran *after* ACP had already claimed the card, and the pins survived.

**Fix.** The `DisableSequence` is gone from `userspace/ucm/sof-soundwire/tas2783.conf`; the
`EnableSequence` stays. Demonstrated A/B live — `alsaucm set _verb HiFi` is exactly what ACP
does at card creation:

| overlay | pins before | pins after | other controls changed |
|---|---|---|---|
| current | `on on on on` | `on on on on` | **none at all** |
| old | `on on on on` | **`off off off off`** | — |

**`disable` was deliberately not used to test this.** `omnibook-ucm-overlay disable` — and
`enable` — restart wireplumber, which is the wedge risk. Patching the file and running
`build` needs no restart; the fix lands at the next card creation.

---

## Using it

```bash
./bin/omnibook-ucm-overlay status     # tree, drift, env, devices offered
./bin/omnibook-ucm-overlay build      # rebuild the farm — touches no services
./bin/omnibook-ucm-overlay check      # asserts the overlay loses no stock device
./bin/omnibook-ucm-overlay enable     # writes the env file, RESTARTS WIREPLUMBER
./bin/omnibook-ucm-overlay disable    # RESTARTS WIREPLUMBER
```

`omnibook-ucm-overlay.service` (user) runs `auto`, which enables the overlay only when the
card can really make a noise and disables it otherwise — a `Speaker` device UCM offers with
no amplifier behind it becomes a silent default sink, which is strictly worse than no
speaker sink at all. The gate requires an amp that is both `Attached` **and** not stuck in PM
error, plus an actual `Speaker` PCM: "Attached" alone is insufficient, because nothing in the
SoundWire core clears a latched `runtime_error` on re-attach.

The three overridden files, and why each exists, are documented at the top of each file in
`userspace/ucm/`.
