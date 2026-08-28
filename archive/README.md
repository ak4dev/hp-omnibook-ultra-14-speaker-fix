# Archive

Raw material behind the analysis in `docs/`. Nothing here is needed to install the fix.

All files are **PII-scrubbed**: hostnames, usernames, home paths, MAC addresses, UUIDs,
private IP addresses and email addresses were replaced before commit.

- `boots/` — preserved kernel logs from the two decisive boots. `2026-08-27-1200` is the
  two-amp boot with the full enumeration trace; `2026-08-27-1404` is the boot that first
  made sound, and carries the timing measurement for defect 4.
  `recorder.txt` in the 1200 directory is garbled — the bug that caused it is described in
  `docs/investigation.md` § 10.4 and fixed in `bin/omnibook-speaker-report`.
- `evidence/` — SOF topology dumps and the RT1308 header used for comparison.
  `evidence/acpi/` is where the DSDT/SSDT dump goes; it has never been taken.
- `dead-ends/` — probes and earlier scripts that did not work, kept for the notes they are
  cited in from `docs/traps.md`.
- `state-history/` — earlier revisions of the research record. **Sessions 3 and 4 are wrong
  in load-bearing places** (see `docs/investigation.md` § 2.0). They are kept only to show
  what was overturned; never quote them.

## Deliberately not archived

- **TI datasheets** (TAS2781 SLOSE86B, TAS2783EVM SLOU557A). Vendor documents under TI's
  copyright — fetch them from TI directly rather than redistributing them here.
- **Build artifacts** (`.ko`, `.o`, `.cmd`, `.mod`) — reproducible from the patches in
  `kernel/`, and locked to one `vermagic` anyway.
- **Vendored kernel sources** — fetched at build time from git.kernel.org for whatever
  kernel is running, so they follow the machine instead of pinning it.
- **A vendored copy of `/usr/share/alsa/ucm2`** — `omnibook-ucm-overlay build` farms the
  installed tree, so it tracks the package.
