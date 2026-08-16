# sourced by distrohop — ~/Dev inventory, clone map, envs, compose volumes
# shellcheck disable=SC2034

DEV_ROOT="${DISTROHOP_DEV:-$HOME/Dev}"

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
  find "$DEV_ROOT" -type f \
    \( -name '.env' -o -name '.env.*' -o -name '.npmrc' -o -name '.envrc' \) \
    ! -name '.env.example' ! -name '*.example' ! -name '.example.env' \
    ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.venv/*' \
    ! -path '*/supabase/.temp/*' ! -path '*/.temp/*' \
    -print 2>/dev/null | sort
}

dev_bind_paths() {
  # extra paths from the [dev] manifest section, plus known compose bind-mounts
  local rel
  if [[ -f $MANIFEST ]]; then
    while IFS= read -r rel; do
      [[ -z $rel ]] && continue
      printf '%s\n' "$rel"
    done < <(parse_manifest dev)
  fi
  local p
  for p in \
    "Dev/Python/myed-backend/data" \
    "Dev/Python/quexter/data"
  do
    [[ -d $HOME/$p ]] && printf '%s\n' "$p"
  done
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
[[ ${1:-} == --dry-run ]] && DRY=1

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
  if git clone -- "$origin" "$dest"; then
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
  local rel src dest
  while IFS= read -r rel; do
    [[ -z $rel ]] && continue
    src="$HOME/$rel"
    [[ -d $src ]] || continue
    dest="$out/bind/$rel"
    if (( DRY_RUN )); then
      printf '  bind %s\n' "$rel"
    else
      mkdir -p "$dest"
      rsync -a --exclude='.git/' --exclude='node_modules/' "$src/" "$dest/"
      printf '%s\n' "$rel" >> "$out/bind/PATHS.txt"
    fi
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

dev_backup_volumes() {
  local out=$1
  mkdir -p "$out/volumes"
  command -v docker >/dev/null 2>&1 || { printf '0\n'; return 0; }
  docker info >/dev/null 2>&1 || { warn "docker not running — skipped volumes"; printf '0\n'; return 0; }

  local img name dest n=0
  img=$(dev_tar_image)
  : > "$out/volumes/NAMES.txt"
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    dest="$out/volumes/${name}.tar.gz"
    info "volume $name"
    if (( DRY_RUN )); then
      printf '  vol  %s\n' "$name"
    else
      docker run --rm \
        -v "$name":/from:ro \
        -v "$out/volumes":/to \
        "$img" tar -C /from -czf "/to/${name}.tar.gz" . \
        || { warn "volume tar failed: $name"; continue; }
      # logical dump when the volume is attached to postgres
      local cid user
      cid=$(docker ps -q --filter "volume=$name" | head -n1 || true)
      if [[ -n $cid ]]; then
        if docker exec "$cid" sh -c 'command -v pg_dumpall' >/dev/null 2>&1; then
          user=$(docker exec "$cid" printenv POSTGRES_USER 2>/dev/null || echo postgres)
          docker exec "$cid" pg_dumpall -U "$user" > "$out/volumes/${name}.sql" 2>/dev/null \
            || warn "pg_dumpall failed for $name (volume tar is enough)"
        fi
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
  mkdir -p "$out"

  dev_write_inventory "$out"
  dev_backup_envs "$out"
  dev_backup_bind "$out"
  dev_backup_volumes "$out"
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
  local rel dest
  while IFS= read -r rel; do
    [[ -z $rel ]] && continue
    dest="$HOME/$rel"
    if (( DRY_RUN )); then
      printf '  bind %s\n' "$rel"
    else
      mkdir -p "$dest"
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
    docker run --rm \
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
  if [[ -x $clone ]]; then
    info "rebuilding $DEV_ROOT from GitHub remotes"
    if (( DRY_RUN )); then
      "$clone" --dry-run || true
    else
      "$clone" || warn "some clones failed (private remotes need gh/ssh auth)"
    fi
  fi

  dev_restore_envs "$snap"
  dev_restore_bind "$snap"
  dev_restore_volumes "$snap"

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

  if [[ -d $DEV_ROOT/Fullstack/parami-erp ]] && command -v supabase >/dev/null 2>&1; then
    info "supabase start  Fullstack/parami-erp"
    (cd "$DEV_ROOT/Fullstack/parami-erp" && supabase start) || warn "supabase start failed"
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
