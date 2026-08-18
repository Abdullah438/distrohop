# sourced by distrohop — S3 / Cloudflare R2 push and pull of full snapshots

S3_CONF="${S3_CONF:-$CONFIG_DIR/s3.conf}"

s3_load_conf() {
  conf_load_kv "$S3_CONF" endpoint bucket prefix access_key secret_key region || return 1
  [[ -n ${endpoint:-} && -n ${bucket:-} && -n ${access_key:-} && -n ${secret_key:-} ]]
}

s3_import_env() {
  local envfile=$1
  [[ -n $envfile ]] || die "usage: distrohop s3 configure ENVFILE"
  [[ -f $envfile ]] || die "no env file at $envfile"
  python3 - "$envfile" "$S3_CONF" <<'PY'
import re, sys
from pathlib import Path
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
vals = {}
for line in src.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    vals[k.strip()] = v.strip().strip("\"'")
need = ("R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")
missing = [k for k in need if not vals.get(k)]
if missing:
    sys.exit("missing in %s: %s" % (src, ", ".join(missing)))
account = vals["R2_ACCOUNT_ID"]
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(
    "# generated from %s — do not commit\n"
    "endpoint=https://%s.r2.cloudflarestorage.com\n"
    "bucket=distrohop\n"
    "prefix=\n"
    "access_key=%s\n"
    "secret_key=%s\n"
    "region=auto\n"
    % (src, account, vals["R2_ACCESS_KEY_ID"], vals["R2_SECRET_ACCESS_KEY"])
)
dest.chmod(0o600)
print(dest)
PY
}

s3_ensure() {
  s3_load_conf && return 0
  die "no S3 config. Copy s3.conf.example to $S3_CONF, or run: distrohop s3 configure ENVFILE"
}

# rclone S3 remote path is remote:BUCKET/key
s3_remote_path() {
  local name=$1
  # Empty prefix is intentional: objects live at bucket/<snapshot>, not bucket/distrohop/<snapshot>.
  local pfx=${prefix-}
  pfx=${pfx#/}; pfx=${pfx%/}
  local b=${bucket:?s3 bucket not set}
  if [[ -n $name && -n $pfx ]]; then
    printf '%s/%s/%s' "$b" "$pfx" "$name"
  elif [[ -n $name ]]; then
    printf '%s/%s' "$b" "$name"
  elif [[ -n $pfx ]]; then
    printf '%s/%s' "$b" "$pfx"
  else
    printf '%s' "$b"
  fi
}

s3_rclone_env() {
  command -v rclone >/dev/null 2>&1 || die "rclone is required for S3 push (pacman -S rclone)"
  s3_ensure
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID=$access_key
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$secret_key
  export RCLONE_CONFIG_R2_ENDPOINT=$endpoint
  export RCLONE_CONFIG_R2_REGION=${region:-auto}
  export RCLONE_CONFIG_R2_ACL=private
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
}

# Make sure the snapshot on disk includes secrets/ before upload.
s3_pack_secrets() {
  local snap=$1
  [[ -f $MANIFEST ]] || ensure_manifest
  mkdir -p "$snap/secrets"
  local rel
  while IFS= read -r rel; do
    [[ -z $rel ]] && continue
    copy_item "$rel" "$snap/secrets" || true
    if ! grep -q $'\t'"$rel"'$' "$snap/MANIFEST.txt" 2>/dev/null; then
      printf '%s\t%s\n' "secrets" "$rel" >> "$snap/MANIFEST.txt"
    fi
  done < <(parse_manifest secrets)
  chmod -R go= "$snap/secrets" 2>/dev/null || true
}

cmd_s3_configure() {
  local from=${1:-}
  mkdir -p "$CONFIG_DIR"
  if [[ -n $from ]]; then
    s3_import_env "$from"
  else
    local example="$SCRIPT_DIR/s3.conf.example"
    [[ -f $example ]] || die "missing $example"
    if [[ ! -f $S3_CONF ]]; then
      cp "$example" "$S3_CONF"
      chmod 600 "$S3_CONF"
    fi
    info "edit $S3_CONF and fill in endpoint / keys"
    return 0
  fi
  s3_load_conf || die "config incomplete"
  ok "wrote $S3_CONF  (bucket=$bucket prefix=${prefix:-<none>})"
  info "objects land at r2:$(s3_remote_path '<name>')"
}

cmd_s3_push() {
  local snap_arg=${1:-}
  local snap
  if [[ -n $snap_arg ]]; then
    snap=$(resolve_snapshot "$snap_arg")
  else
    # full backup including secrets, then upload
    WANT_SECRETS=1
    [[ -n $NAME_OVERRIDE ]] || NAME_OVERRIDE="workstation-$(date +%Y-%m-%d_%H%M%S)"
    cmd_backup
    snap="${DEST_OVERRIDE:-$DATA_DIR}/$NAME_OVERRIDE"
  fi
  [[ -d $snap ]] || die "snapshot not found"

  if (( ! DRY_RUN )); then
    info "including secrets in the upload"
    s3_pack_secrets "$snap"
  fi

  s3_rclone_env
  local name dest
  name=$(basename "$snap")
  dest="r2:$(s3_remote_path "$name")"
  info "s3 push  $snap  →  $dest"
  if (( DRY_RUN )); then
    rclone copy "$snap" "$dest" --dry-run -P
    return 0
  fi
  rclone copy "$snap" "$dest" -P --s3-no-check-bucket
  if (( ! WANT_NO_VERIFY )); then
    info "verifying upload"
    rclone check "$snap" "$dest" --one-way || die "verification FAILED for $name — re-run: distrohop s3 push $name"
  fi
  ok "uploaded $name  ($(du -sh "$snap" | awk '{print $1}'))"
  info "pull later with:  distrohop s3 pull $name"
}

cmd_s3_pull() {
  local name=${1:-}
  [[ -n $name ]] || die "usage: distrohop s3 pull NAME"
  s3_rclone_env
  local dest="${DEST_OVERRIDE:-$DATA_DIR}/$name"
  mkdir -p "$(dirname "$dest")"
  local src
  src=$(s3_remote_path "$name")
  if [[ -z ${prefix-} ]]; then
    if ! rclone lsf "r2:${src}" --max-depth 1 2>/dev/null | grep -q .; then
      local old="${bucket}/distrohop/${name}"
      if rclone lsf "r2:${old}" --max-depth 1 2>/dev/null | grep -q .; then
        warn "using legacy key ${old} (older pushes nested a distrohop/ prefix)"
        src=$old
      fi
    fi
  fi
  info "s3 pull  ${src}  →  $dest"
  if (( DRY_RUN )); then
    rclone copy "r2:${src}" "$dest" --dry-run -P
    return 0
  fi
  rclone copy "r2:${src}" "$dest" -P --s3-no-check-bucket
  if (( ! WANT_NO_VERIFY )); then
    info "verifying download"
    rclone check "r2:${src}" "$dest" --one-way || die "verification FAILED for $dest — re-run: distrohop s3 pull $name"
  fi
  ok "pulled $dest"
}

cmd_s3_ls() {
  s3_rclone_env
  local pfx
  pfx=$(s3_remote_path "")
  pfx=${pfx%/}
  info "listing r2:${pfx}"
  rclone lsd "r2:${pfx}" 2>/dev/null || rclone ls "r2:${pfx}" | head -50
}

cmd_s3_prune() {
  local keep=${KEEP_N:-$PRUNE_DEFAULT_KEEP}
  [[ $keep =~ ^[0-9]+$ ]] || die "--keep must be a non-negative integer"
  s3_rclone_env
  local pfx
  pfx=$(s3_remote_path "")
  pfx=${pfx%/}

  local names=() n
  while IFS= read -r n; do
    [[ -n $n ]] && names+=("${n%/}")
  done < <(rclone lsf "r2:${pfx}" --dirs-only 2>/dev/null | sort)
  local total=${#names[@]}
  if (( total <= keep )); then
    info "$total remote snapshot(s), keeping $keep — nothing to prune"
    return 0
  fi

  local drop=$(( total - keep )) i name
  info "$total remote snapshot(s), keeping $keep newest — pruning $drop"
  for (( i = 0; i < drop; i++ )); do
    name=${names[i]}
    if (( DRY_RUN )); then
      printf '  would delete r2:%s\n' "$(s3_remote_path "$name")"
      continue
    fi
    if rclone purge "r2:$(s3_remote_path "$name")"; then
      ok "deleted $name"
    else
      warn "failed to delete $name"
    fi
  done
  (( DRY_RUN )) && ok "dry-run finished ($drop would be deleted)"
}

cmd_s3() {
  local sub=${1:-}
  shift || true
  case $sub in
    configure) cmd_s3_configure "${1:-}" ;;
    push)      cmd_s3_push "${1:-}" ;;
    pull)      cmd_s3_pull "${1:-}" ;;
    ls|list)   cmd_s3_ls ;;
    prune)     cmd_s3_prune ;;
    *) die "usage: distrohop s3 configure|push|pull|ls|prune  [NAME]" ;;
  esac
}
