# sourced by distrohop — ~/Dev inventory, clone map, envs, compose volumes
# shellcheck disable=SC2034

DEV_ROOT="${DISTROHOP_DEV:-${dev_root:-$HOME/Dev}}"

# Best-effort desktop notification for the cases where distrohop hits a wall
# it can't work around unattended (e.g. no docker, no terminal to ask
# for sudo) — mainly for the systemd timer, where nothing else would ever
# tell you a backup/restore came back incomplete.
dev_notify() {
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -a distrohop "distrohop" "$1" 2>/dev/null || true
}

dev_have_tty() { [[ -t 0 && -c /dev/tty ]]; }

dev_repos() {
  # prints: relpath<TAB>branch<TAB>origin
  [[ -d $DEV_ROOT ]] || return 0
  local gitdir repo rel branch origin
  while IFS= read -r -d '' gitdir; do
    repo=$(dirname "$gitdir")
    rel=${repo#"$DEV_ROOT"/}
    [[ $rel == "$repo" ]] && continue
    case $rel in
      */node_modules/*|*/.venv/*|*/venv/*) continue ;;
    esac
    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    origin=$(git -C "$repo" remote get-url origin 2>/dev/null || echo "")
    printf '%s\t%s\t%s\n' "$rel" "$branch" "$origin"
  done < <(find "$DEV_ROOT" -type d -name .git \
    ! -path '*/node_modules/*' ! -path '*/.venv/*' ! -path '*/venv/*' \
    -print0 2>/dev/null | sort -z)
}

dev_env_files() {
  [[ -d $DEV_ROOT ]] || return 0
  # find exits 1 on unreadable (container-owned) dirs — never propagate that
  find "$DEV_ROOT" -type f \
    \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name '.npmrc' -o -name '.envrc' \) \
    ! -name '.env.example' ! -name '*.example' ! -name '.example.env' \
    ! -name '*.pre-hop.*' \
    ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.venv/*' \
    ! -path '*/supabase/.temp/*' ! -path '*/.temp/*' \
    -print 2>/dev/null | sort || true
}

dev_bind_paths() {
  # extra bind-mount / data dirs from the [dev] manifest section — add yours
  # with `distrohop edit`.
  local rel
  if [[ -f $MANIFEST ]]; then
    while IFS= read -r rel; do
      [[ -z $rel ]] && continue
      printf '%s\n' "$rel"
    done < <(parse_manifest dev)
  fi
  return 0
}

dev_named_volumes() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  local name project
  while IFS='|' read -r name project; do
    [[ -z $name ]] && continue
    [[ $name =~ ^[0-9a-f]{64}$ ]] && continue
    case $name in
      *node_modules*|supabase_edge_runtime*) continue ;;
    esac
    if [[ -n $project ]] && [[ -d $DEV_ROOT ]] && find "$DEV_ROOT" -maxdepth 3 -type d -name "$project" -print -quit | grep -q .; then
      printf '%s\n' "$name"
    fi
  done < <(docker volume ls -q 2>/dev/null | while read -r v; do
    docker volume inspect "$v" --format '{{.Name}}|{{index .Labels "com.docker.compose.project"}}' 2>/dev/null
  done)
}

write_clone_script() {
  local dest=$1
  cat > "$dest" <<'EOF'
#!/usr/bin/env bash
# Rebuild ~/Dev from the recorded GitHub remotes. Safe to run on a blank home.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEV_ROOT="${DISTROHOP_DEV:-$HOME/Dev}"
LIST="$HERE/repos.tsv"
DRY=0
USE_GH=0
for arg in "$@"; do
  case $arg in
    --dry-run) DRY=1 ;;
    --gh)      USE_GH=1 ;;
  esac
done

if [[ ! -f $LIST ]]; then
  echo "missing $LIST" >&2
  exit 1
fi

cloned=0
skipped=0
failed=0
local_only=0

while IFS=$'\t' read -r rel branch origin || [[ -n ${rel:-} ]]; do
  [[ -z ${rel:-} || $rel == \#* ]] && continue
  dest="$DEV_ROOT/$rel"
  if [[ -d $dest/.git ]]; then
    printf 'skip  %s (already a git repo)\n' "$rel"
    skipped=$((skipped + 1))
    continue
  fi
  if [[ -z $origin ]]; then
    printf 'local %s (no origin — cannot clone)\n' "$rel"
    local_only=$((local_only + 1))
    continue
  fi
  printf 'clone %s\n      %s  (%s)\n' "$rel" "$origin" "${branch:-default}"
  if (( DRY )); then
    cloned=$((cloned + 1))
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  ok_clone=0
  if (( USE_GH )); then
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh not installed — falling back to git clone" >&2
      USE_GH=0
    fi
  fi
  if (( USE_GH )); then
    if gh repo clone "$origin" "$dest"; then
      ok_clone=1
    fi
  elif git clone -- "$origin" "$dest"; then
    ok_clone=1
  fi
  if (( ok_clone )); then
    if [[ -n $branch && $branch != HEAD ]]; then
      git -C "$dest" checkout "$branch" 2>/dev/null || \
        echo "note: branch $branch missing on remote, left at default" >&2
    fi
    cloned=$((cloned + 1))
  else
    echo "failed: $rel" >&2
    failed=$((failed + 1))
  fi
done < "$LIST"

printf '\ncloned %s  skipped %s  local-only %s  failed %s\n' \
  "$cloned" "$skipped" "$local_only" "$failed"
(( failed == 0 ))
EOF
  chmod +x "$dest"
}

dev_write_inventory() {
  local out=$1
  mkdir -p "$out"
  {
    printf '# path\tbranch\torigin\n'
    dev_repos
  } > "$out/repos.tsv"
  write_clone_script "$out/clone-dev.sh"

  # machine-readable copy for restore
  python3 - "$out/repos.tsv" "$out/inventory.json" "$DEV_ROOT" <<'PY'
import json, sys
tsv, dest, root = sys.argv[1], sys.argv[2], sys.argv[3]
repos = []
with open(tsv, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        rel = parts[0]
        branch = parts[1] if len(parts) > 1 else ""
        origin = parts[2] if len(parts) > 2 else ""
        repos.append({"path": rel, "branch": branch, "origin": origin})
json.dump({"dev_root": "Dev", "home_dev": root, "repos": repos}, open(dest, "w"), indent=2)
PY
}

dev_backup_envs() {
  local out=$1
  mkdir -p "$out/envs"
  local src rel dest n=0
  while IFS= read -r src; do
    [[ -z $src ]] && continue
    rel=${src#"$DEV_ROOT"/}
    dest="$out/envs/$rel"
    mkdir -p "$(dirname "$dest")"
    if (( DRY_RUN )); then
      printf '  env  %s\n' "$rel"
    else
      cp -a "$src" "$dest"
    fi
    n=$((n + 1))
  done < <(dev_env_files)
  return 0
}

dev_backup_bind() {
  local out=$1
  mkdir -p "$out/bind"
  : > "$out/bind/PATHS.txt"
  local rel src dest errlog img
  while IFS= read -r rel; do
    [[ -z $rel ]] && continue
    src="$HOME/$rel"
    [[ -d $src ]] || continue
    dest="$out/bind/$rel"
    errlog="$dest.errors.log"
    if (( DRY_RUN )); then
      printf '  bind %s\n' "$rel"
      continue
    fi

    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest" "$dest.tar.gz"
    mkdir -p "$dest"
    if rsync -a --exclude='.git/' --exclude='node_modules/' "$src/" "$dest/" 2> "$errlog"; then
      rm -f "$errlog"
      printf '%s\n' "$rel" >> "$out/bind/PATHS.txt"
      continue
    fi

    # Some entries need root to read (a redis/postgres data dir owned by the
    # container's service uid, often mixed with plain host-owned files
    # elsewhere under the same configured path). Archive it via root instead
    # of mirroring loose files: tar preserves the real per-file owner/mode,
    # and a single root-owned .tar.gz (created world-readable by default)
    # is still something we can archive/push afterward, unlike a directory
    # tree of 600-mode files owned by a uid we aren't. Try silently via
    # docker first (works unattended, e.g. the systemd timer); if that's
    # not available, ask for sudo when there's a terminal to ask on; if
    # neither applies, notify (best-effort) and fall back to whatever the
    # plain rsync above already managed to copy.
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      warn "bind $rel: rsync hit read errors as your user — archiving via docker as root instead"
      img=$(dev_tar_image)
      if docker run --rm --user 0 \
          -v "$src":/from:ro -v "$(dirname "$dest")":/to \
          "$img" tar -C /from -czf "/to/$(basename "$dest").tar.gz" .; then
        rm -rf "$dest" "$errlog"
        printf '%s\ttar\n' "$rel" >> "$out/bind/PATHS.txt"
        continue
      fi
      warn "bind $rel: privileged archive via docker failed"
      rm -f "$dest.tar.gz"
    elif dev_have_tty; then
      warn "bind $rel: rsync hit read errors as your user — enter your password to read it as root (sudo)"
      if sudo tar -C "$src" -czf "$dest.tar.gz" . && sudo chown "$(id -u):$(id -g)" "$dest.tar.gz"; then
        rm -rf "$dest" "$errlog"
        printf '%s\ttar\n' "$rel" >> "$out/bind/PATHS.txt"
        continue
      fi
      warn "bind $rel: sudo archive failed too"
      rm -f "$dest.tar.gz"
    else
      dev_notify "backup: '$rel' has files distrohop can't read (permission denied) — install docker, or run 'distrohop backup' in a terminal to unlock it with sudo"
    fi

    warn "bind $rel: permission denied on some files — see $(basename "$errlog"); backup is incomplete for this path"
    printf '%s\n' "$rel" >> "$out/bind/PATHS.txt"
  done < <(dev_bind_paths | sort -u)
}

dev_tar_image() {
  if docker image inspect postgres:16-alpine >/dev/null 2>&1; then
    printf '%s\n' postgres:16-alpine
  elif docker image inspect alpine >/dev/null 2>&1; then
    printf '%s\n' alpine
  else
    printf '%s\n' alpine
  fi
}

# Logical dump per postgres volume — must run while containers are still up.
dev_backup_pg_dumps() {
  local out=$1
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  local name cid user
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    cid=$(docker ps -q --filter "volume=$name" | head -n1 || true)
    [[ -n $cid ]] || continue
    if docker exec "$cid" sh -c 'command -v pg_dumpall' >/dev/null 2>&1; then
      user=$(docker exec "$cid" printenv POSTGRES_USER 2>/dev/null || echo postgres)
      info "pg_dumpall $name"
      (( DRY_RUN )) && continue
      docker exec "$cid" pg_dumpall -U "$user" > "$out/volumes/${name}.sql" 2>/dev/null \
        || warn "pg_dumpall failed for $name (volume tar is enough)"
    fi
  done < <(dev_named_volumes)
}

# Running containers that mount a named volume we back up, or bind-mount
# into one of the [dev] data dirs. Printed one id per line.
dev_containers_to_stop() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  local vols binds
  vols=$(dev_named_volumes)
  binds=$(dev_bind_paths | sort -u | while read -r rel; do
    [[ -n $rel && -d $HOME/$rel ]] && printf '%s\n' "$HOME/$rel"
  done)

  local cid mtype mname msrc root hit
  while IFS= read -r cid; do
    [[ -z $cid ]] && continue
    hit=0
    while IFS='|' read -r mtype mname msrc; do
      [[ -z $mtype ]] && continue
      if [[ $mtype == volume && -n $mname ]]; then
        if printf '%s\n' "$vols" | grep -qxF "$mname"; then hit=1; break; fi
      elif [[ $mtype == bind && -n $msrc ]]; then
        while IFS= read -r root; do
          [[ -z $root ]] && continue
          if [[ $msrc == "$root" || $msrc == "$root"/* ]]; then hit=1; break 2; fi
        done <<< "$binds"
      fi
    done < <(docker inspect "$cid" --format '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
    (( hit )) && printf '%s\n' "$cid"
  done < <(docker ps -q 2>/dev/null)
}

# Stop containers so volume/bind copies are consistent and nothing holds
# files open. Prints the ids that were actually stopped (info → stderr).
dev_stop_containers() {
  local cid cname
  while IFS= read -r cid; do
    [[ -z $cid ]] && continue
    cname=$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null || true)
    cname=${cname#/}
    if docker stop "$cid" >/dev/null 2>&1; then
      info "stopped container ${cname:-$cid}" >&2
      printf '%s\n' "$cid"
    else
      warn "could not stop ${cname:-$cid} — copying it live" >&2
    fi
  done < <(dev_containers_to_stop)
}

# Restart in reverse order so dependencies (db) come up before apps.
dev_start_containers() {
  local -a ids=("$@")
  local i cid cname
  for (( i=${#ids[@]}-1; i>=0; i-- )); do
    cid=${ids[i]}
    [[ -z $cid ]] && continue
    cname=$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null || true)
    cname=${cname#/}
    if docker start "$cid" >/dev/null 2>&1; then
      info "started container ${cname:-$cid}"
    else
      warn "failed to restart ${cname:-$cid} — start it by hand"
    fi
  done
}

dev_backup_volumes() {
  local out=$1
  mkdir -p "$out/volumes"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    warn "docker unavailable — skipped volumes"
    return 0
  fi

  local img name dest errlog n=0
  img=$(dev_tar_image)
  : > "$out/volumes/NAMES.txt"
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    dest="$out/volumes/${name}.tar.gz"
    errlog="$out/volumes/${name}.errors.log"
    info "volume $name"
    if (( DRY_RUN )); then
      printf '  vol  %s\n' "$name"
    else
      rm -f "$dest" "$errlog"
      # --user 0: some images (e.g. redis's data dir is owned by uid 999)
      # would otherwise archive as a non-root default user and hit denied
      # reads on every file. Even as root, a handful of entries can still
      # fail (sockets, files a live process deletes mid-tar) — that's not
      # worth losing the whole volume over, so keep whatever tar produced
      # and only treat it as a real failure if the archive came out empty.
      docker run --rm --user 0 \
        -v "$name":/from:ro \
        -v "$out/volumes":/to \
        "$img" tar -C /from -czf "/to/${name}.tar.gz" . \
        2> "$errlog"
      if [[ ! -s $dest ]]; then
        warn "volume tar failed: $name"
        rm -f "$dest" "$errlog"
        continue
      fi
      if [[ -s $errlog ]]; then
        warn "volume $name: backed up with some entries skipped (see volumes/$(basename "$errlog"))"
      else
        rm -f "$errlog"
      fi
    fi
    printf '%s\n' "$name" >> "$out/volumes/NAMES.txt"
    n=$((n + 1))
  done < <(dev_named_volumes)
}

dev_status() {
  group_wanted dev || return 0
  printf '%s[dev]%s  %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$DEV_ROOT" "$C_RESET"
  local n
  n=$(dev_repos | wc -l)
  printf '  repos     %s  (clone map — source stays on GitHub)\n' "$n"
  dev_repos | while IFS=$'\t' read -r rel branch origin; do
    if [[ -z $origin ]]; then
      printf '    %s%-40s  %s  (no origin)%s\n' "$C_DIM" "$rel" "$branch" "$C_RESET"
    else
      printf '    %-40s  %s\n' "$rel" "$origin"
    fi
  done
  n=$(dev_env_files | wc -l)
  printf '  envs      %s\n' "$n"
  n=$(dev_bind_paths | sort -u | while read -r p; do [[ -d $HOME/$p ]] && echo "$p"; done | wc -l)
  printf '  bind-data %s\n' "$n"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    n=$(dev_named_volumes | wc -l)
    printf '  volumes   %s\n' "$n"
    dev_named_volumes | sed 's/^/    /'
  else
    printf '  volumes   (docker unavailable)\n'
  fi
  printf '\n'
}

dev_backup() {
  local snap=$1
  local out="$snap/dev"
  mkdir -p "$out" "$out/volumes"

  dev_write_inventory "$out"
  dev_backup_envs "$out"
  dev_backup_pg_dumps "$out"

  # Stop containers that touch the volumes / data dirs so the copies below
  # are consistent and nothing is held open mid-read. Restarted right after.
  local -a stopped=()
  if (( ! DRY_RUN )); then
    mapfile -t stopped < <(dev_stop_containers)
    ((${#stopped[@]})) && info "containers paused for the copy: ${#stopped[@]}"
  fi

  dev_backup_bind "$out" || warn "bind backup had errors"
  dev_backup_volumes "$out" || warn "volume backup had errors"

  if ((${#stopped[@]})); then
    dev_start_containers "${stopped[@]}"
  fi

  dev_backup_pm2 "$out"

  cat > "$out/.gitignore" <<'EOF'
# Keep the clone map (repos.tsv, clone-dev.sh, inventory.json) in git.
# These directories hold secrets and database dumps — do not push them
# to a public remote. Fine in a private repo you accept the risk for.
envs/
volumes/
bind/
dump.pm2
EOF

  chmod -R go= "$out/envs" 2>/dev/null || true

  local nrepos nenv nvol
  nrepos=$(grep -cEv '^\s*(#|$)' "$out/repos.tsv" || true)
  nenv=$(find "$out/envs" -type f 2>/dev/null | wc -l)
  nvol=$(grep -cEv '^\s*(#|$)' "$out/volumes/NAMES.txt" 2>/dev/null || true)

  printf '%s\tdev/repos.tsv\n' "dev" >> "$snap/MANIFEST.txt"
  ok "dev: $nrepos repos mapped, $nenv envs, $nvol volumes"
  info "rebuild ~/Dev with:  $out/clone-dev.sh"
}

dev_restore_envs() {
  local snap=$1
  local src="$snap/dev/envs"
  [[ -d $src ]] || return 0
  local f rel dest n=0
  while IFS= read -r -d '' f; do
    rel=${f#"$src"/}
    dest="$DEV_ROOT/$rel"
    if (( DRY_RUN )); then
      printf '  env  %s\n' "$rel"
    else
      mkdir -p "$(dirname "$dest")"
      if [[ -e $dest ]]; then
        cp -a "$dest" "$dest.pre-hop.$(date +%Y%m%d%H%M%S)"
      fi
      cp -a "$f" "$dest"
    fi
    n=$((n + 1))
  done < <(find "$src" -type f -print0)
  info "envs restored: $n"
}

dev_restore_bind() {
  local snap=$1
  local src="$snap/dev/bind"
  [[ -f $src/PATHS.txt ]] || return 0
  local rel kind dest img tarfile
  while IFS=$'\t' read -r rel kind; do
    [[ -z $rel ]] && continue
    dest="$HOME/$rel"
    if (( DRY_RUN )); then
      printf '  bind %s\n' "$rel"
      continue
    fi

    mkdir -p "$dest"
    if [[ $kind == tar ]]; then
      tarfile="$src/$rel.tar.gz"
      if [[ ! -f $tarfile ]]; then
        warn "bind $rel: missing $(basename "$tarfile") — skipping"
        continue
      fi
      if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        img=$(dev_tar_image)
        if docker run --rm --user 0 \
            -v "$dest":/to -v "$(dirname "$tarfile")":/from:ro \
            "$img" tar -C /to -xzf "/from/$(basename "$tarfile")"; then
          continue
        fi
        warn "bind $rel: privileged restore via docker failed"
      elif dev_have_tty; then
        warn "bind $rel: enter your password to restore it with its original ownership (sudo)"
        sudo tar -C "$dest" -xzf "$tarfile" && continue
        warn "bind $rel: sudo restore failed too"
      else
        dev_notify "restore: '$rel' needs root to restore with its original ownership — install docker, or run 'distrohop restore' in a terminal to unlock it with sudo"
      fi
      warn "bind $rel: not restored — run by hand: sudo tar -C '$dest' -xzf '$tarfile'"
    else
      rsync -a "$src/$rel/" "$dest/"
    fi
  done < "$src/PATHS.txt"
}

dev_restore_volumes() {
  local snap=$1
  local src="$snap/dev/volumes"
  [[ -f $src/NAMES.txt ]] || return 0
  command -v docker >/dev/null 2>&1 || { warn "docker not installed — skip volume restore"; return 0; }
  docker info >/dev/null 2>&1 || { warn "docker not running — skip volume restore"; return 0; }

  local img name
  img=$(dev_tar_image)
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    [[ -f $src/${name}.tar.gz ]] || { warn "missing $name.tar.gz"; continue; }
    info "volume $name"
    if (( DRY_RUN )); then
      continue
    fi
    docker volume create "$name" >/dev/null
    docker run --rm --user 0 \
      -v "$name":/to \
      -v "$src":/from:ro \
      "$img" tar -C /to -xzf "/from/${name}.tar.gz" \
      || warn "volume extract failed: $name"
  done < "$src/NAMES.txt"
}

dev_restore() {
  local snap=$1
  [[ -d $snap/dev ]] || return 0

  local clone="$snap/dev/clone-dev.sh"
  if restore_wanted clone && [[ -x $clone ]]; then
    local args=()
    (( DRY_RUN )) && args+=(--dry-run)
    (( WANT_GH )) && args+=(--gh)
    info "rebuilding $DEV_ROOT from GitHub remotes$( (( WANT_GH )) && printf ' (gh repo clone)' )"
    "$clone" "${args[@]}" || warn "some clones failed (private remotes need: gh auth login)"
  fi

  restore_wanted envs && dev_restore_envs "$snap"
  restore_wanted bind && dev_restore_bind "$snap"
  restore_wanted volumes && dev_restore_volumes "$snap"

  if (( WANT_UP )) && (( ! DRY_RUN )); then
    dev_compose_up "$snap"
  fi
}

dev_compose_up() {
  local snap=$1
  [[ -d $DEV_ROOT ]] || return 0
  local compose
  while IFS= read -r -d '' compose; do
    info "compose up  ${compose#"$DEV_ROOT"/}"
    (cd "$(dirname "$compose")" && docker compose up -d) \
      || warn "compose failed: $compose"
  done < <(find "$DEV_ROOT" -maxdepth 4 -type f \( -name docker-compose.yml -o -name docker-compose.yaml \) \
    ! -path '*/node_modules/*' -print0 2>/dev/null)

  if command -v supabase >/dev/null 2>&1; then
    local cfg proj
    while IFS= read -r -d '' cfg; do
      proj=$(dirname "$(dirname "$cfg")")
      info "supabase start  ${proj#"$DEV_ROOT"/}"
      (cd "$proj" && supabase start) || warn "supabase start failed: $proj"
    done < <(find "$DEV_ROOT" -maxdepth 4 -type f -name config.toml -path '*/supabase/*' \
      ! -path '*/node_modules/*' -print0 2>/dev/null)
  fi

  if command -v pm2 >/dev/null 2>&1 && [[ -f $HOME/.pm2/dump.pm2 || -f $snap/dev/dump.pm2 ]]; then
    [[ -f $snap/dev/dump.pm2 && ! -f $HOME/.pm2/dump.pm2 ]] && mkdir -p "$HOME/.pm2" && cp "$snap/dev/dump.pm2" "$HOME/.pm2/dump.pm2"
    info "pm2 resurrect"
    pm2 resurrect || warn "pm2 resurrect failed — start each ecosystem.config.cjs by hand"
  fi
}

dev_backup_pm2() {
  local out=$1
  if [[ -f $HOME/.pm2/dump.pm2 ]]; then
    cp -a "$HOME/.pm2/dump.pm2" "$out/dump.pm2"
  elif command -v pm2 >/dev/null 2>&1; then
    pm2 save >/dev/null 2>&1 || true
    [[ -f $HOME/.pm2/dump.pm2 ]] && cp -a "$HOME/.pm2/dump.pm2" "$out/dump.pm2"
  fi
}
