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

`~/Dev` git trees are never copied. The snapshot records each GitHub remote and folder (`Fullstack/khata`, `Python/myed-backend`, …) plus a `clone-dev.sh` that rebuilds the tree.

`.env` files and docker volumes *are* copied (they are not in git). They sit under `dev/envs` and `dev/volumes` and are gitignored so a public push of this app does not leak them.

Copy `~/Backups/distrohop/` onto a USB, or commit the clone map (`dev/repos.tsv`, `dev/clone-dev.sh`) with this repo.

## Restore

```bash
distrohop install
distrohop restore workstation               # configs + clone ~/Dev + envs/volumes
distrohop clone workstation                 # only rebuild ~/Dev from GitHub
distrohop restore workstation --up          # then docker compose / supabase / pm2
distrohop bootstrap                         # zsh, p10k, plugins, fonts (Arch)
distrohop packages apply --portable
```

Private remotes need `gh auth login` or SSH keys (`--secrets` on backup).

Desktop settings (dconf) can be saved and reloaded with `distrohop dconf export` / `import` after the session is up.

Edit what gets copied: `distrohop edit`.
