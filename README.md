# distrohop

Snapshot the configs and workspace map that should survive a reinstall, then put them back. The tool does not assume which distro or desktop you came from or are going to.

## Install

```bash
git clone https://github.com/Abdullah438/distrohop.git ~/Dev/distrohop
cd ~/Dev/distrohop
./distrohop install
```

That symlinks `~/.local/bin/distrohop` and writes `~/.config/distrohop/manifest.conf`. Make sure `~/.local/bin` is on your `PATH`.

## Backup

```bash
distrohop status
distrohop backup --name workstation
distrohop backup --name workstation --secrets --archive
```

Default groups are `core apps gtk editor packages dev`. Secrets are opt-in (`--secrets`). Containers that touch the backed-up docker volumes or data dirs are stopped before the copy and started again right after, so the copies are consistent.

`~/Dev` git trees are never copied. The snapshot records each GitHub remote and folder (`Fullstack/khata`, `Python/myed-backend`, …) plus a `clone-dev.sh` that rebuilds the tree.

`.env` files and docker volumes *are* copied (they are not in git). They sit under `dev/envs` and `dev/volumes` and are gitignored so a public push of this app does not leak them.

Backup also writes `packages/dev-apps.json` — Cursor, VS Code, Docker, nvm, pyenv, and similar tools that were on the machine, with enough detail to try an automated reinstall later.

Copy `~/Backups/distrohop/` onto a USB, or commit the clone map (`dev/repos.tsv`, `dev/clone-dev.sh`) with this repo.

## Restore

On a TTY, restore opens a checkbox list of what is in the snapshot. Tick what you want (secrets, package install, and development apps are optional). `--yes` skips the prompt and restores the defaults. `--groups` skips the prompt and restores only what you listed.

```bash
distrohop install
distrohop restore workstation               # checkbox picker
distrohop restore workstation --yes         # defaults, no prompt
distrohop restore workstation --up          # then docker compose / supabase / pm2
distrohop clone workstation                 # only rebuild ~/Dev from GitHub
distrohop bootstrap                         # zsh, p10k, plugins, fonts (Arch)
distrohop packages apply --portable
```

If you tick **development apps**, distrohop tries the native package manager (**pacman/AUR**, **dnf**, or **apt**), then nvm / pyenv / npm. Arch names are mapped (e.g. `github-cli` → `gh`, `docker` → `docker.io` on Debian). Anything with no package (Cursor, Postman, Android Studio, …) is listed as a manual step.

Private remotes: `distrohop clone workstation --gh` uses `gh repo clone` (needs `gh auth login`). Without `--gh` it is plain `git clone`.

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
```

Keys can be imported from khata’s `R2_*` env (`distrohop s3 configure`). The bucket is always **`distrohop`** — create that in the R2 dashboard; do not reuse khata’s `receipts` bucket.

```bash
distrohop s3 configure                    # import R2 keys from khata → s3.conf
distrohop s3 push workstation             # upload an existing snapshot (adds secrets)
distrohop s3 push                         # take a full backup (with secrets) and upload
distrohop s3 ls
distrohop s3 pull workstation
```

If an older push created a `distrohop/` folder inside the bucket, those objects are at `distrohop/distrohop/<name>`. Re-push after this fix, or copy them up one level in the R2 dashboard.

Desktop settings (dconf) can be saved and reloaded with `distrohop dconf export` / `import` after the session is up.

Edit what gets copied: `distrohop edit`.
