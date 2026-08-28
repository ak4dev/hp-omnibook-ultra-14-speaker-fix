# Traps

Every one of these cost a working session once. Read before debugging anything in this
stack. Line numbers are Linux 7.1.9.

## Unrecoverable without a reboot — know these first

- **A `context.objects` entry in `pipewire.conf.d` that cannot be created KILLS THE WHOLE
  PIPEWIRE DAEMON.** Not the node — the daemon. Observed with the Speaker PCM held by a
  leaked substream: `pipewire.service` died in 24 ms, hit its start limit, and the machine
  had **no audio at all**, not even USB, until the file was moved away. The log reads
  `conf.c create_object(): can't create object from factory adapter` then
  `pipewire.c main(): failed to create context`. **Always carry `flags = [ nofail ]`.**
  The systemd exit code (240) is a red herring — it is systemd's `EXIT_LOGS_DIRECTORY`
  label for a code PipeWire chose itself. Run `/usr/bin/pipewire` in the foreground to see
  the real error.

- **The Speaker PCM can be left wedged by a dead process, and only a reboot clears it.**
  After a PipeWire restart cycle, `/proc/asound/card*/pcm2p/sub0/status` read
  `state: SETUP owner_pid: <pid>` with that pid dead and reaped — a leaked ALSA substream.
  Every open then fails `Device or resource busy`, `aplay` included, with **no** process
  holding an fd on `/dev/snd/pcmC*D2p`. Nothing in userspace frees it.
  **It escalates.** Left alone, the wedge spread from the PCM to the card's *control*
  interface: `amixer controls` and `alsactl restore` then hang in **uninterruptible sleep**,
  which neither `timeout(1)` nor `SIGKILL` can clear. **The moment the PCM reports a dead
  `owner_pid`, stop touching that card entirely** — every further `amixer`/`alsactl`/`aplay`
  just parks another unkillable process.
  PipeWire itself survives as long as ACP holds the card at profile `off` and the speaker
  node carries `nofail`.

- **Restarting `pipewire`/`wireplumber` while the speaker node holds the PCM is what wedges
  it.** Do not restart the audio stack while the Speaker sink exists. To change the UCM
  overlay's content, edit `userspace/ucm/` and run `omnibook-ucm-overlay build` — that
  touches no services and lands at the next card creation. Note that `enable` and `disable`
  both *do* restart wireplumber.

- **Never unbind or rebind on a live card.** Tearing down `sof-soundwire` breaks the HDA
  HDMI codec, which cannot re-probe at runtime (`HDMI: failed to get afg sub nodes` →
  `sof_sdw: failed to instantiate card -22`). You lose the whole card until reboot.

- **Never unbind a single `slave-tas2783` device either.** `tas_sdw_remove()` →
  `snd_soc_unregister_component()` deletes a component of an instantiated card and unbinds
  the **whole** card — Jack Out, Speaker, HDMI 1–3, Deepbuffer and mics. It does not clear
  `runtime_error`. Maximum blast radius, zero payoff.

## Testing

- **SHORT TONE BURSTS ARE NOT A VALID LISTENING TEST ON THESE AMPS.** 1.2–2.0 s bursts of a
  single 600 Hz tone were reported silent on an amplifier that a 6–8 s frequency sweep at
  the same amplitude then made *clearly* audible. The TAS2783 runs a smart-amp algorithm
  with its own gating and ramping. **Always test with a sweep of ≥ 5 s**, and treat any
  "silent" result from a burst as unproven. Two conclusions built on bursts were both wrong.

- **Ask a human whether they were in the room.** A listening test nobody observed does not
  return "no result", it returns a false negative.

- **A `-22` in a boot log is not automatically the amps failing.** Something opening the
  Speaker PCM before an amp has finished its firmware download gives
  `error playback without fw download` + `ASoC error (-22)`, and playback works fine
  afterwards. Check the download completion timestamps first.

## Reading the state

- **The ALSA card index is not stable.** It depends on what else is present at boot: with a
  USB headset attached the card is index 1, without it index 0. On 2026-08-28 the reference
  machine booted with no USB audio, `sof-soundwire` took index 0, and every hardcoded
  `hw:1,2` in this fix silently pointed at nothing — no speaker sink at all, on an otherwise
  perfectly healthy kernel side. **Always address the card by ID** (`hw:CARD=sofsoundwire`,
  `amixer -c sofsoundwire`, `/proc/asound/sofsoundwire/`).

- **`device_number = N/A` does not mean "never enumerated."** It is returned for *any* slave
  whose `status == SDW_SLAVE_UNATTACHED`, without ever reading `dev_num`
  (`sysfs_slave.c:237-246`).

- **`-61` is `-ENODATA`** — `SDW_CMD_IGNORED`, the peripheral did not ACK
  (`bus.c:224-225`). Not a missing file, and not proof the bus was dead.

- **`fw with no files` is a consequence**, not a parsing bug: `tas2783_fw_ready()` breaks
  its per-file loop on the first failed write, leaving `cur_file == 0`.

- **`Found Smart Amp function at index 0` does not mean the amp is on the bus.** It is
  printed from the codec probe for `UNATTACHED` peripherals as well.

- **`0x110` in a Slave status change means devices 1 AND 2**, one nibble per device — not
  "the device-2 pair".

- **`amixer`'s simple mixer cannot see the TAS2783 controls.** `amixer sset 'Right Spk
  Switch' on` fails with "Unable to find simple control". Use `cset numid=N` or
  `cset name='...'`; `amixer controls` lists them, `amixer contents` shows values.

- **Only the surviving amps register mixer controls.** Any config naming `tas2783-1` or
  `tas2783-3` on a machine where those died silently finds nothing. The four DAPM pin
  switches exist regardless — they are card-level widgets from `lr_4spk_widgets`, not
  per-codec controls.

- **The kernel's speaker names do not describe this chassis.**
  `asoc_sdw_ti_spk_rtd_init()` maps tas2783-1→"Left Spk", -2→"Right Spk", -3→"Left Spk2",
  -4→"Right Spk2". Measured by ear: both amps the kernel calls "Right" are physically on the
  **left**. Device 1 on each link is the left pair, device 2 the right pair.

- **There is no `/proc/asound/card*/components` on this kernel.** The components string
  lives in the ALSA card info; `amixer -c <card> info` reads it without needing a PipeWire
  session.

## Power management

- **`power/control` offers no "force suspend".** `on` is `pm_runtime_forbid()` (a get),
  `auto` is `pm_runtime_allow()` (the matching put); the pair returns you where you started.
  There is no sysfs lever that drops a held reference.

- **Nothing under `power/` clears `runtime_error`.** `runtime_status` is `DEVICE_ATTR_RO`
  and only *prints* `"error"`, masking the real status. The only clearers in the kernel are
  `__pm_runtime_set_status()` and `pm_runtime_init()`, and a `slave-tas2783` unbind reaches
  neither — `pm_runtime_reinit()` acts only when `runtime_status == RPM_ACTIVE`, and a
  failed resume leaves `RPM_SUSPENDED`.
  Root-free probe: if `runtime_suspended_time` advances at wall-clock rate while
  `runtime_active_time` is frozen and `runtime_status` reads `error`, the device is
  `RPM_SUSPENDED` with runtime PM enabled.

- **`.idle_bias_on = 1`** in `soc_codec_driver_tasdevice` (`tas2783-sdw.c:1027-1038`) makes
  ASoC pin every amp `runtime_status=active` forever once the `sof_sdw` card has bound,
  which pins its links active too. The mechanism is spent by the time you have a shell.

- **A completed s2idle does NOT bring the dead amps back.** It is the strongest reset the
  kernel has and it fails. Do not spend a session hoping suspend/resume is the workaround.

- **`TIMEOUT_FW_DL_MS` is 3000 ms** (`tas2783-sdw.c:42`), so `tas_io_init()` can block for up
  to three seconds in `wait_event_timeout()` under `cdns->status_update_lock`, stalling every
  other peripheral on the link. An observed 1.186 s completion is not the code's limit.

## Modules and building

- **Never `zstd -o` straight over a live `.ko.zst`.** An interrupted run leaves a truncated
  archive where the kernel will look for the module, and the failure is silent. The
  `install_module` helper compresses to a temp path, `zstd -t`s it, checks `vermagic`, keeps
  `.stock` exactly once, then renames.

- **A patched module is not a signed module.** The stock `.ko.zst` files carry `intree: Y`
  and a PKCS#7 signature; anything built here carries neither. Harmless where Secure Boot is
  off — but never write "matches the stock module exactly".

- **`revert` is a full teardown, not an experiment undo.** It restores every `.stock` it
  finds, including the working defect-1 module. After a module experiment, undo that one
  module by hand (`mv …ko.zst.stock …ko.zst; depmod -a $(uname -r)`).

- **Dynamic debug is not a free variable.** `dev_dbg` printk inside
  `cdns_update_slave_status_work()` runs under `cdns->status_update_lock`, so a traced boot
  is not directly comparable to an untraced one. Arm it anyway — a boot without it teaches
  nothing — but say so when comparing boots.

- **Do not upgrade the kernel expecting a fix.** `find_sdca_function()`'s DC-value check is
  byte-identical at 7.1, 7.2 and master. Mainline `cadence_master.c` and `bus.c` contain no
  retry or rescan work for defect 4. See [porting.md](porting.md).

## UCM

- **Our own UCM overlay muted the speakers at every boot** until it was found. Any
  `DisableSequence` in the overlay runs at *every* card creation via HiFi's `disdevall ""` —
  alsa-lib's `run_device_all_sequence()` (`ucm/main.c:712-736`) runs the `DisableSequence` of
  **every** device in the verb unconditionally, enabled or not, whenever the verb is set.
  Think twice before adding one back. Full account in [ucm.md](ucm.md).

- **`ucm-overlay check` was silently useless when run from an enabled session** — the ambient
  `ALSA_CONFIG_UCM2` leaked into its "stock" side, so its one safety assertion compared the
  tree against itself and could never fire. Fixed with `env -u`; carry that if you copy the
  pattern.

- **`cp -rs` cannot mirror `/usr/share/alsa/ucm2`** — it rewrites the stock *relative*
  symlinks into absolute paths back into `/usr`, so the card's entry point resolves to the
  stock file and every override is silently ignored. `omnibook-ucm-overlay build` walks the
  tree by hand instead.

- **Never leave `.bak-*` files inside the overlay source tree.** `build` farms every file in
  it as an override.

## This machine specifically

- **`sudo` needs a physical FIDO2 touch**, and fails outright from a non-interactive shell:
  it prints "Please touch the FIDO authenticator", falls back to a password prompt, then
  dies with "a terminal is required to read the password".

- **THE ROOT FILESYSTEM IS UNLOCKED BY THE FIDO2 KEY.** A reboot does not come back on its
  own — it parks at the key's PIN/touch prompt, or after the token timeout at a passphrase
  prompt. There is no session, no sshd and no new journal until a human is at the console.
  **Install, reboot and verification are one attended sitting**, and any experiment whose
  revert needs a reboot is only reversible with a person present. This is the single most
  important operational fact about the reference machine.
