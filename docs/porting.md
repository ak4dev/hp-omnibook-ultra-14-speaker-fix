# Surviving a kernel upgrade

> **A kernel upgrade silently destroys both out-of-tree modules.** New `vermagic`, and the
> packaged modules come back. `pacman -Qkk linux` already reports both as size/SHA
> mismatches — pacman owns those paths and will overwrite them without a word.

The failure mode is worse than it sounds on a machine whose root filesystem needs a
physical key: the next unheld `-Syu` plus a reboot takes both modules and the working
speakers with them, and the rebuild can only happen *after* the attended reboot that broke
it.

## Hold the kernel

On Arch, add under `[options]` in `/etc/pacman.conf`:

```
IgnorePkg = linux
```

`linux-firmware` is safe to keep upgrading — the symlinks in `/usr/lib/firmware/updates/`
are name-based and survive it.

## When you do upgrade

Rebuild **both** modules before rebooting into the new kernel:

```bash
sudo ./bin/omnibook-speaker-fix sdca
sudo ./bin/omnibook-speaker-fix sdw-utils
```

Both subcommands fetch `v$(uname -r | cut -d- -f1)` sources from git.kernel.org, so they
follow the running kernel automatically. If a patch does not apply cleanly:

- **`kernel/sdca/`** is a single hunk in `find_sdca_function()`, around the
  `"function type only supported as DisCo constant"` error return — easy to re-place by
  hand. `kernel/sdca/sdca_functions.c.v7.1.9-reference` is the v7.1.9 file the patch was
  generated against, for three-way merging.
  **Known: 7.2 needs a rebase** — `sdca_parse_function()` changed signature.
- **`kernel/sdw-utils/`** adds a self-contained static function plus one guarded `continue`
  inside `asoc_sdw_parse_sdw_endpoints()`. Re-place it beside the `dev_dbg("Add dev: ...")`
  call.

## What each kernel version changes

| Version | Effect |
|---|---|
| ≤ 7.1 | everything in [defects.md](defects.md) applies |
| **7.2** | defect 2 retires itself — `e26bb459d0f3` asks for the `0x` firmware name and falls back, and the driver grew a `fw_use_fallback` flag. `omnibook-speaker-fix firmware` becomes a no-op on its own. Defect 1 still needs the module, and `kernel/sdca/` needs a source rebase |
| mainline | defect 1's `find_sdca_function()` check is unchanged; defect 4 has no retry or rescan work at all. `tas2783-sdw.c` has moved a lot (fallback firmware names, a `writeable_reg` callback, `regcache_drop_region()` on attach, `sdw_slave_wait_for_init()`) — none of it aimed at this |

**A pacman hook or a DKMS package is the durable answer** if you keep the machine. Neither
is written yet.

## Verifying after an upgrade

```bash
./bin/omnibook-speaker-fix check
./bin/omnibook-speaker-fix verify
cat /var/log/omnibook-speaker/latest.txt
```

Good: four `assuming SmartAmp`, four `Found Smart Amp`, no `Direct firmware load ... failed`,
a `device 2: Speaker` PCM, and a "Laptop Speakers" sink in `pactl list short sinks`.
