# The last mile — what actually delivers sound

The kernel half gives you a `Speaker` PCM. It does **not** give you a sink: PipeWire's ACP
layer builds no `HiFi` profile for this card, so the card sits at profile `off` with a null
sink. Three root-free pieces, all under `$HOME`, turn the PCM into a working default sink.

Install them with `./bin/omnibook-speaker-fix userspace` — as your normal user, **not** with
sudo.

---

## 1. `~/.asoundrc` — the channel summing

Defines `pcm.omnibook_spk`: a `plug` over a `route` whose ttable sums both input channels
into slave channel 0 at 0.5 each.

**Why it is necessary.** After the endpoint filter drops the dead amplifiers, both surviving
amps read SoundWire stream **channel 0**. Measured: a sweep in the LEFT channel of the
Speaker PCM is audible from both live amps, a sweep in the RIGHT channel is silent. So a
plain stereo open silently discards every right-channel sample.

The ttable index order is `ttable.<client>.<slave>` — confirmed against
`/usr/share/alsa/cards/ATIIXP-MODEM.conf`, which routes client channel 0 to slave channel 1
as `ttable.0.1`. So `ttable.0.0 0.5` + `ttable.1.0 0.5` sums both client channels into slave
channel 0. Confirmed by ear: content in both channels is audible.

It addresses the card as `hw:CARD=sofsoundwire,DEV=2`, never `hw:1,2` — see
[traps.md](traps.md) "the ALSA card index is not stable".

## 2. `~/.config/pipewire/pipewire.conf.d/50-omnibook-laptop-speaker.conf` — the sink

Creates an `api.alsa.pcm.sink` adapter node named **"Laptop Speakers"** on `omnibook_spk`,
2 ch FL/FR, 48 kHz.

**`flags = [ nofail ]` is load-bearing.** Without it, a `context.objects` entry that cannot
be created aborts PipeWire's whole context and the daemon exits — the machine loses *all*
audio, not just the speakers. See [traps.md](traps.md).

**Declaring the node MONO does not work.** With `audio.channels = 1` and
`audio.position = [ MONO ]` the adapter still exposes `playback_FL`/`playback_FR`, `pactl`
still reports `s32le 2ch`, and PipeWire routes FL only — so right-channel content is dropped
exactly as with a raw stereo open. Verified live. **Do the summing in ALSA, not in
PipeWire.**

### 2b. `~/.config/systemd/user/pipewire.service.d/10-omnibook-wait-for-card.conf`

Holds PipeWire's start until the Speaker PCM node exists. On one boot `pipewire.service`
started at monotonic 20.88 and the card registered at 22.65 — 1.8 s later — and with
`nofail` that means no speaker sink until something restarts PipeWire. Proven on a later
boot: the race happened and the drop-in absorbed it, blocking 3.01 s.

Bounded at 45 s and always exits 0, so a machine with no internal speakers still starts
PipeWire normally.

> **This drop-in has a side effect.** By making PipeWire start *later*, it inverted the
> ordering that had been accidentally protecting the DAPM pin switches, and exposed the UCM
> muting bug described in [ucm.md](ucm.md). Both are fixed; the interaction is worth knowing
> if you change either.

## 3. `~/.local/bin/omnibook-speaker-mixer` + its user unit — the mixer restore

Restores the amp mixer state from `~/.config/omnibook-speaker/asound.state` at session
start. It waits up to 60 s for a control matching `Spk` to exist, because the codec
components do not register controls until the card binds ~22 s into boot.

It is ordered **`After=pipewire.service wireplumber.service`**, not before: all four DAPM pin
switches were observed being turned **off** across a `pipewire`+`wireplumber` restart, which
silences the speakers while leaving the amps `Attached` and the volumes at 200. Restoring
before the audio stack starts loses that race.

Root-free by design: `alsactl --file` writes under `$HOME`, never
`/var/lib/alsa/asound.state`, so the system `alsa-restore.service` is untouched.

There is no state file in this repo — it is machine state, not configuration. Create one
once the speakers work:

```bash
alsactl --file ~/.config/omnibook-speaker/asound.state store sofsoundwire
```

---

## The controls that matter

Only these four exist; the dead amps register none:

| Control | Range |
|---|---|
| `tas2783-2 Speaker Volume` | 0–200, 200 = 0 dB |
| `tas2783-4 Speaker Volume` | 0–200, 200 = 0 dB |
| `Right Spk Switch` | DAPM pin |
| `Right Spk2 Switch` | DAPM pin |

(The amp numbers depend on which survive. All four DAPM pin switches — `Left Spk`,
`Right Spk`, `Left Spk2`, `Right Spk2` — exist regardless, and the kernel's left/right
naming does not describe this chassis. See [traps.md](traps.md).)

`amixer`'s **simple** mixer cannot see any of them. Use:

```bash
amixer -c sofsoundwire controls
amixer -c sofsoundwire cset numid=N 1
amixer -c sofsoundwire cset name='Right Spk Switch' 1
```

## Testing it

Remember: **sweeps of ≥ 5 s, never short tone bursts** ([traps.md](traps.md)).

```bash
speaker-test -D omnibook_spk -c 2 -r 48000 -t sine -f 200 -l 1 &   # then let it run
```

or play a real file through the "Laptop Speakers" sink and listen for at least five seconds.
