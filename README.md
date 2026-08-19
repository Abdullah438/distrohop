# distrohop

Snapshot the configs, dev-environment state, and package lists that should survive a reinstall, then put them back. distrohop doesn't assume a specific distro, desktop environment, or folder layout — it works with pacman, dnf, apt, or zypper, detects the live desktop session instead of hardcoding one, and every dev-tree path is something you configure, not something baked in.

## Requirements

- `bash`, `rsync`, `python3` — required, used for every backup/restore.
- `docker` — optional, only needed to back up/restore named volumes and compose bind-mounts.
- `rclone` — optional, only needed for `distrohop s3` (R2/S3 push/pull).
- `gh`, `paru`, `flatpak`, `pm2`, `supabase`, `dconf` — optional, each used only if the corresponding feature applies to your setup.

## Install

```bash
git clone https://github.com/Abdullah438/distrohop.git ~/Dev/distrohop
cd ~/Dev/distrohop
./distrohop install
```

That symlinks `~/.local/bin/distrohop` and writes `~/.config/distrohop/manifest.conf`. Make sure `~/.local/bin` is on your `PATH`.

By default your dev tree is expected at `~/Dev`. If it lives somewhere else, set it once:

```bash
distrohop config set dev_root ~/Projects
```

(or export `DISTROHOP_DEV` for a one-off override).

## Backup

```bash
distrohop status
distrohop backup --name workstation
distrohop backup --name workstation --secrets --archive
distrohop backup --name workstation --secrets --push  # backup, then upload to S3/R2
```

Default groups are `core apps gtk editor packages dev`. Secrets are opt-in (`--secrets`). Containers that touch the backed-up docker volumes or data dirs are stopped before the copy and started again right after, so the copies are consistent.

`--push` uploads the snapshot to S3/R2 right after it's written (same as running `distrohop s3 push NAME` afterward) — see [S3 / Cloudflare R2](#s3--cloudflare-r2) for setup. It does not force `--secrets`; only what you told `backup` to include gets uploaded.

Your dev tree's git trees are never copied. The snapshot records each GitHub remote and folder (e.g. `Fullstack/myapp`, `Python/mylib`, …) plus a `clone-dev.sh` that rebuilds the tree.

`.env` files and docker volumes *are* copied (they are not in git). They sit under `dev/envs` and `dev/volumes` and are gitignored so a public push of this app does not leak them.

Backup also writes `packages/dev-apps.json` — Cursor, VS Code, Docker, nvm, pyenv, and similar tools that were on the machine, with enough detail to try an automated reinstall later.

Copy `~/Backups/distrohop/` onto a USB, or commit the clone map (`dev/repos.tsv`, `dev/clone-dev.sh`) with this repo.

Old snapshots pile up — `distrohop prune` deletes everything but the 10 most recent (`--keep N` to change that, `--dry-run` to preview).

## Restore

On a TTY, restore opens a checkbox list of what is in the snapshot. Tick what you want (secrets, package install, and development apps are optional). `--yes` skips the prompt and restores the defaults. `--groups` skips the prompt and restores only what you listed.

```bash
distrohop install
distrohop restore workstation               # checkbox picker
distrohop restore workstation --yes         # defaults, no prompt
distrohop restore workstation --up          # then docker compose / supabase / pm2
distrohop restore workstation --pull        # download from S3/R2 first, then restore
distrohop clone workstation                 # only rebuild ~/Dev from GitHub
distrohop bootstrap                         # zsh, p10k, plugins, fonts
distrohop packages apply --portable
```

If you tick **development apps**, distrohop tries the native package manager (**pacman/AUR**, **dnf**, **apt**, or **zypper**), then nvm / pyenv / npm. Arch names are mapped (e.g. `github-cli` → `gh`, `docker` → `docker.io` on Debian). Anything with no package (Cursor, Postman, Android Studio, …) is listed as a manual step.

`distrohop bootstrap` installs zsh/p10k/plugins as system packages on Arch (AUR via `paru`); on dnf/apt/zypper it installs what's packaged and git-clones the rest into `~/.local/share/distrohop/zsh-plugins`.

The desktop-session package split (packages you'd rather not reinstall on a portable machine) ships a KDE/pacman classifier out of the box; on any other desktop or distro, list glob patterns under `[packages_exclude]` in the manifest (`distrohop edit`) to get the same effect.

Private remotes: `distrohop clone workstation --gh` uses `gh repo clone` (needs `gh auth login`). Without `--gh` it is plain `git clone`.

Leftover `*.pre-hop.*` backups from past restores don't clean themselves up — `distrohop clean` lists them, `distrohop clean --older-than 30` removes anything 30+ days old (`--dry-run` to preview).

## S3 / Cloudflare R2

Uploads the **whole** snapshot, including `secrets/`, `.env` files, and docker volumes.

Objects land at `bucket/<snapshot-name>` (for example `distrohop/workstation`). Leave `prefix=` empty in `s3.conf` — a non-empty prefix would nest an extra folder inside the bucket.

Runtime credentials are **`~/.config/distrohop/s3.conf`** (not a `.env`, not in git, not inside the R2 snapshot). Keep a copy of that file somewhere else (1Password, USB) — it is the bootstrap. On a blank machine you need it first, then you can pull:

```bash
# 1. restore s3.conf from your offline copy
mkdir -p ~/.config/distrohop
# put s3.conf there (chmod 600)
distrohop s3 pull workstation
distrohop restore workstation --gh
# equivalent to the two commands above:
distrohop restore workstation --pull --gh
```

Keys can be imported from any `.env` file with `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` set (`distrohop s3 configure ENVFILE`). The bucket is always **`distrohop`** — create that in the R2 dashboard.

```bash
distrohop s3 configure ~/path/to/project/.env  # import R2 keys → s3.conf
distrohop s3 push workstation                  # upload an existing snapshot (adds secrets)
distrohop s3 push                              # take a full backup (with secrets) and upload
distrohop s3 ls
distrohop s3 pull workstation
distrohop s3 prune --keep 5                    # delete all but the 5 newest remote snapshots
```

Every push/pull is checksum-verified against the remote afterward (`--no-verify` to skip).

If an older push created a `distrohop/` folder inside the bucket, those objects are at `distrohop/distrohop/<name>`. Re-push after this fix, or copy them up one level in the R2 dashboard.

Desktop settings (dconf) can be saved and reloaded with `distrohop dconf export` / `import` after the session is up.

Edit what gets copied: `distrohop edit`.
