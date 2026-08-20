# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

distrohop is a single bash CLI (`./distrohop`) that snapshots configs and dev-environment state before a distro reinstall/hop, then restores them on the new box. Community tool (public GitHub repo), not a personal script — treat README/UX/error messages as user-facing. It is not a dotfiles symlink manager (it copies, never symlinks) and doesn't image whole systems.

## Running / testing

There's no build step and no test suite — it's a plain bash script.

```bash
./distrohop help                    # usage
./distrohop status                  # dry preview of what backup would copy, no test framework needed
./distrohop backup --name test --dry-run
./distrohop restore SNAPSHOT --dry-run
shellcheck distrohop lib/*.sh       # the closest thing to CI here
```

To exercise a command end-to-end without touching your real `~/Backups`, override the destination and manifest:

```bash
DISTROHOP_DIR=/tmp/dh-test ./distrohop backup --name smoke --dest /tmp/dh-test
```

`set -euo pipefail` is on — any new code must handle empty globs / missing commands explicitly rather than relying on default bash leniency.

## Architecture

`./distrohop` is the entrypoint and dispatcher; it resolves through symlinks to find `SCRIPT_DIR`, then sources everything in `lib/` unconditionally (order matters — `conf.sh` and `ui.sh` before the modules that call into them):

- `lib/conf.sh` — generic `key=value` file loader (`conf_load_kv`), used by both `manifest.conf`-adjacent settings and `s3.conf`.
- `lib/ui.sh` — the interactive restore checkbox picker. Three backends tried in order: raw-tty arrow-key UI (`ui_checklist_tty`), `whiptail`, then a numbered-input fallback — picked automatically based on what the terminal supports.
- `lib/pm.sh` — package manager abstraction over pacman/dnf/apt/zypper (detect, list explicit/user-installed packages, check availability, install, and map an Arch package name to its equivalent on other distros via `pm_map_pkg`).
- `lib/dev-apps.sh` — a catalog-driven detector/installer for dev tools that aren't OS packages (Cursor, VS Code, nvm, pyenv, Docker Desktop, etc.) — backs up which are present with version info, tries automated reinstall via `pm_map_pkg` + package manager, falls back to a printed manual step.
- `lib/dev.sh` — everything under the `dev` group: walks `$DEV_ROOT` (default `~/Dev`) for git repos and records remote+branch (never copies `.git` trees — `clone-dev.sh` rebuilds them from GitHub), finds stray `.env`/`.npmrc` files, backs up Docker named volumes (tar via a throwaway container) and compose bind-mounts, stops/restarts containers around the copy for consistency, and does postgres logical dumps when possible.
- `lib/s3.sh` — S3/R2 push/pull via `rclone` (configured through env vars, not an rclone.conf file, so nothing but this script touches the remote credentials). Handles the legacy double-nested-prefix bug transparently on pull.

The main `distrohop` script owns: arg parsing, the manifest system (`[group]` sections in `manifest.conf`, parsed by `parse_manifest`), the `copy_item`/`restore_item` rsync wrappers (restore always backs up clobbered files as `*.pre-hop.TIMESTAMP` — never a silent overwrite), package list dumping/classification (`dump_packages`, `classify_packages` — splits out KDE-only packages so a "portable" package install skips desktop-session cruft), and all `cmd_*` command implementations dispatched at the bottom via a `case` on `$1`.

### Groups and manifest

Backup/restore is organized into named groups (`core apps gtk editor packages dev secrets extra`), defined as HOME-relative paths under `[group]` headers in `manifest.conf` (user's live copy lives at `~/.config/distrohop/manifest.conf`, seeded from the bundled one on first run via `ensure_manifest`). `--groups` overrides the default set entirely; `--with` adds to it. `secrets` is always opt-in (`--secrets`), never part of the default group list, and gets `chmod go=` after every copy. `[packages_exclude]` holds glob patterns (any distro/DE) for dropping specific packages from the "portable" install list — the KDE split in `distrohop` is just a convenience prefill of that same mechanism for pacman+KDE.

### Snapshot layout

A snapshot directory (`~/Backups/distrohop/<name>/`) contains `files/` (mirrors `$HOME` for core/apps/gtk/editor/extra groups), `secrets/` (only if `--secrets`), `dev/` (repos.tsv, clone-dev.sh, inventory.json, envs/, bind/, volumes/), `packages/` (per-package-manager lists), `meta/`, `MANIFEST.txt` (tab-separated `group<TAB>relpath`, the source of truth restore reads to know what group each restored file belongs to), and `NOTES.txt`. `resolve_snapshot` accepts a bare name (looked up under `$DATA_DIR`), a path, or a glob-matched prefix.

### Key invariants to preserve

- Git trees under `$DEV_ROOT` are never copied directly — only remote URL + branch, reconstructed via `clone-dev.sh` on restore.
- Restore never clobbers silently: existing files/dirs at the destination get moved to `*.pre-hop.<timestamp>` first.
- `secrets` never enters the default group set implicitly — only explicit `--secrets` or explicit `--groups`/`--with` inclusion.
- Docker containers touching backed-up volumes/binds are stopped before copy and always restarted after (reverse order, DB-like deps first) — even on partial failure paths.
- S3 pushes are checksum-verified against the remote by default (`rclone check --one-way`); `--no-verify` is opt-out, not default.
- `DRY_RUN` must be honored by any new copy/backup/restore/S3 code path — check `(( DRY_RUN ))` before mutating anything.
