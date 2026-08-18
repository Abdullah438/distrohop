# sourced by distrohop — record and reinstall main development apps

# id \t label \t detectors (a|b|c) \t packages \t extra-note
devapps_catalog() {
  cat <<'EOF'
cursor	Cursor	pkg:cursor-bin|cmd:cursor|path:~/.local/bin/cursor	cursor-bin	If the package is missing, install from https://cursor.com
code	Visual Studio Code	pkg:visual-studio-code-bin|pkg:code|cmd:code	visual-studio-code-bin	Or https://code.visualstudio.com
zed	Zed	pkg:zed|cmd:zed	zed
docker	Docker	pkg:docker|cmd:docker	docker docker-compose docker-buildx	Then: sudo systemctl enable --now docker && sudo usermod -aG docker $USER (log out/in)
github-cli	GitHub CLI	pkg:github-cli|cmd:gh	github-cli	Then: gh auth login
dbeaver	DBeaver	pkg:dbeaver|cmd:dbeaver	dbeaver
postman	Postman	pkg:postman-bin|cmd:postman	postman-bin	Or https://www.postman.com/downloads
android-studio	Android Studio	pkg:android-studio|cmd:android-studio	android-studio	SDK / emulator setup is manual inside the IDE on first launch
supabase	Supabase CLI	pkg:supabase-bin|cmd:supabase	supabase-bin
rclone	rclone	pkg:rclone|cmd:rclone	rclone
cloudflared	cloudflared	pkg:cloudflared|cmd:cloudflared	cloudflared
alacritty	Alacritty	pkg:alacritty|cmd:alacritty	alacritty
tmux	tmux	pkg:tmux|cmd:tmux	tmux
jdk	OpenJDK	pkg:jdk-openjdk|cmd:javac	jdk-openjdk
neovim	Neovim	pkg:neovim|cmd:nvim	neovim
EOF
}

devapps_cmd_path() {
  local c=$1 p
  p=$(type -P "$c" 2>/dev/null) || return 1
  case $p in
    *cursor-agent*) return 1 ;;
  esac
  printf '%s\n' "$p"
}

devapps_detect_one() {
  local spec=$1
  local kind=${spec%%:*} rest=${spec#*:}
  rest=${rest/#\~/$HOME}
  case $kind in
    cmd)
      devapps_cmd_path "$rest" >/dev/null
      ;;
    pkg)
      pacman -Q "$rest" >/dev/null 2>&1 && return 0
      rpm -q "$rest" >/dev/null 2>&1 && return 0
      dpkg-query -W -f='${Status}' "$rest" 2>/dev/null | grep -q 'install ok installed'
      ;;
    path)
      [[ -e $rest || -L $rest ]]
      ;;
    dir)
      [[ -d $rest ]]
      ;;
    *)
      return 1
      ;;
  esac
}

devapps_expand_home() { printf '%s' "${1/#\~/$HOME}"; }

devapps_nvm_info() {
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  [[ -s $nvm_dir/nvm.sh ]] || return 1
  local ver default
  if [[ -f $nvm_dir/package.json ]]; then
    ver=$(python3 -c "import json; print(json.load(open('$nvm_dir/package.json')).get('version',''))" 2>/dev/null || true)
  fi
  [[ -n $ver ]] || ver=$(git -C "$nvm_dir" describe --tags 2>/dev/null | sed 's/^v//' || true)
  default=""
  [[ -f $nvm_dir/alias/default ]] && default=$(<"$nvm_dir/alias/default")
  local versions=() d
  for d in "$nvm_dir"/versions/node/v*; do
    [[ -d $d ]] || continue
    versions+=("$(basename "$d")")
  done
  python3 - "$ver" "$default" "${versions[*]}" <<'PY'
import json, sys
ver, default, vers = sys.argv[1], sys.argv[2], sys.argv[3].split()
json.dump({"version": ver, "default": default, "installed": vers}, sys.stdout)
PY
}

devapps_pyenv_info() {
  local root="${PYENV_ROOT:-$HOME/.pyenv}"
  [[ -d $root ]] || command -v pyenv >/dev/null 2>&1 || return 1
  [[ -d $root ]] || root=$(pyenv root 2>/dev/null || true)
  [[ -d $root ]] || return 1
  local versions=() d
  for d in "$root"/versions/*; do
    [[ -d $d ]] || continue
    [[ $(basename "$d") == system ]] && continue
    versions+=("$(basename "$d")")
  done
  local ver=""
  command -v pyenv >/dev/null 2>&1 && ver=$(pyenv --version 2>/dev/null | awk '{print $2}')
  python3 - "$ver" "${versions[*]}" <<'PY'
import json, sys
ver, vers = sys.argv[1], sys.argv[2].split()
json.dump({"version": ver, "installed": vers}, sys.stdout)
PY
}

devapps_npm_globals() {
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  local known='pm2 pnpm yarn typescript vercel wrangler nodemon serve'
  local found=() nodever dir pkg
  for dir in "$nvm_dir"/versions/node/v*/lib/node_modules; do
    [[ -d $dir ]] || continue
    nodever=$(basename "$(dirname "$(dirname "$dir")")")
    for pkg in $known; do
      if [[ -d $dir/$pkg ]]; then
        found+=("$pkg@$nodever")
      fi
    done
  done
  # pnpm may be a corepack shim in bin/
  for dir in "$nvm_dir"/versions/node/v*/bin; do
    [[ -e $dir/pnpm ]] || continue
    nodever=$(basename "$(dirname "$dir")")
    [[ " ${found[*]} " == *" pnpm@$nodever "* ]] && continue
    found+=("pnpm@$nodever")
  done
  printf '%s\n' "${found[@]}"
}

devapps_backup() {
  local snap=$1
  local out="$snap/packages"
  mkdir -p "$out"

  local apps_json="[]"
  local id label detectors packages note
  local det matched via
  while IFS=$'\t' read -r id label detectors packages note || [[ -n ${id:-} ]]; do
    [[ -z ${id:-} || $id == \#* ]] && continue
    matched=0
    via=""
    IFS='|' read -ra det <<< "$detectors"
    local d
    for d in "${det[@]}"; do
      if devapps_detect_one "$d"; then
        matched=1
        via=$d
        break
      fi
    done
    (( matched )) || continue
    apps_json=$(APP_ID="$id" APP_LABEL="$label" APP_VIA="$via" APP_PKGS="$packages" APP_NOTE="${note:-}" APP_JSON="$apps_json" python3 - <<'PY'
import json, os
apps = json.loads(os.environ["APP_JSON"])
apps.append({
    "id": os.environ["APP_ID"],
    "label": os.environ["APP_LABEL"],
    "detected_via": os.environ["APP_VIA"],
    "packages": os.environ["APP_PKGS"].split(),
    "note": os.environ.get("APP_NOTE", ""),
})
print(json.dumps(apps))
PY
)
  done < <(devapps_catalog)

  local nvm_json="null" pyenv_json="null"
  nvm_json=$(devapps_nvm_info 2>/dev/null || echo null)
  pyenv_json=$(devapps_pyenv_info 2>/dev/null || echo null)
  local npm_list
  npm_list=$(devapps_npm_globals | paste -sd' ' -)

  python3 - "$out/dev-apps.json" "$apps_json" "$nvm_json" "$pyenv_json" "$npm_list" <<'PY'
import json, sys
dest, apps, nvm, pyenv, npm = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
doc = {
    "apps": json.loads(apps),
    "nvm": None if nvm == "null" else json.loads(nvm),
    "pyenv": None if pyenv == "null" else json.loads(pyenv),
    "npm_globals": [x for x in npm.split() if x],
}
json.dump(doc, open(dest, "w"), indent=2)
PY

  python3 - "$out/dev-apps.json" "$out/dev-apps.txt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
lines = [
    "distrohop development apps",
    "==========================",
    "AUTO  = distrohop will try pacman/AUR, dnf, or apt, then nvm / pyenv / npm",
    "MANUAL = you still have a step (auth, SDK, group membership, website download)",
    "",
]
for a in doc.get("apps") or []:
    pkgs = " ".join(a.get("packages") or [])
    lines.append(f"AUTO   {a['label']:<22} packages: {pkgs}")
    if a.get("note"):
        lines.append(f"       {a['note']}")
nvm = doc.get("nvm")
if nvm:
    vers = ", ".join(nvm.get("installed") or []) or "(none)"
    lines.append(f"AUTO   nvm                    v{nvm.get('version') or '?'}  default={nvm.get('default') or ''}  node={vers}")
    lines.append("       If the installer fails: https://github.com/nvm-sh/nvm#installing-and-updating")
pyenv = doc.get("pyenv")
if pyenv:
    vers = ", ".join(pyenv.get("installed") or []) or "(none)"
    lines.append(f"AUTO   pyenv                  {pyenv.get('version') or ''}  python={vers}")
    lines.append("       Then: pyenv install <version> && pyenv global <version>")
for g in doc.get("npm_globals") or []:
    name = g.split("@", 1)[0]
    lines.append(f"AUTO   npm -g {name:<14} {g}")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY

  local n
  n=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('apps') or []))" "$out/dev-apps.json")
  ok "dev apps: $n recorded → packages/dev-apps.txt"
}

devapps_status() {
  local id label detectors packages note matched
  printf '%s[dev-apps]%s\n' "$C_BOLD" "$C_RESET"
  local n=0
  while IFS=$'\t' read -r id label detectors packages note || [[ -n ${id:-} ]]; do
    [[ -z ${id:-} || $id == \#* ]] && continue
    matched=0
    local d
    IFS='|' read -ra det <<< "$detectors"
    for d in "${det[@]}"; do
      if devapps_detect_one "$d"; then
        matched=1
        break
      fi
    done
    (( matched )) || continue
    printf '  %-22s %s\n' "$label" "$packages"
    n=$((n + 1))
  done < <(devapps_catalog)
  if [[ -s ${NVM_DIR:-$HOME/.nvm}/nvm.sh ]]; then
    printf '  %-22s nvm\n' "nvm"
    n=$((n + 1))
  fi
  if [[ -d ${PYENV_ROOT:-$HOME/.pyenv} ]] || command -v pyenv >/dev/null 2>&1; then
    printf '  %-22s pyenv\n' "pyenv"
    n=$((n + 1))
  fi
  printf '  %s%s recorded on backup%s\n\n' "$C_DIM" "$n" "$C_RESET"
}

# pm_detect/pm_map_pkg live in lib/pm.sh (shared with the main script); keep
# these names as thin aliases so the rest of this file doesn't need renaming.
devapps_pm() { pm_detect; }
devapps_map_pkg() { pm_map_pkg "$@"; }

devapps_provides_cmd() {
  case $1 in
    cursor-bin) printf '%s\n' cursor ;;
    visual-studio-code-bin|code) printf '%s\n' code ;;
    zed) printf '%s\n' zed ;;
    docker|docker.io|docker-ce|moby-engine) printf '%s\n' docker ;;
    github-cli|gh) printf '%s\n' gh ;;
    dbeaver|dbeaver-ce) printf '%s\n' dbeaver ;;
    postman-bin|postman) printf '%s\n' postman ;;
    android-studio) printf '%s\n' android-studio ;;
    supabase-bin|supabase) printf '%s\n' supabase ;;
    rclone) printf '%s\n' rclone ;;
    cloudflared) printf '%s\n' cloudflared ;;
    alacritty) printf '%s\n' alacritty ;;
    tmux) printf '%s\n' tmux ;;
    jdk-openjdk|default-jdk|*-openjdk*) printf '%s\n' javac ;;
    neovim) printf '%s\n' nvim ;;
    pyenv) printf '%s\n' pyenv ;;
  esac
}

devapps_pkg_installed_pm() { pm_pkg_installed "$@"; }
devapps_pkg_available() { pm_pkg_available "$@"; }

devapps_pkg_manual_hint() {
  case $1 in
    cursor-bin) printf '%s\n' "Cursor — https://cursor.com (no apt/dnf package)" ;;
    postman-bin) printf '%s\n' "Postman — https://www.postman.com/downloads" ;;
    android-studio) printf '%s\n' "Android Studio — https://developer.android.com/studio" ;;
    supabase-bin) printf '%s\n' "Supabase CLI — https://github.com/supabase/cli#install-the-cli" ;;
    visual-studio-code-bin) printf '%s\n' "VS Code — https://code.visualstudio.com (enable the Microsoft/VS Code repo, or download the .deb/.rpm)" ;;
    *) printf '%s\n' "$1 — no package with this name on $(devapps_pm); install the distro equivalent by hand" ;;
  esac
}

devapps_try_packages() {
  local pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  local pm
  pm=$(devapps_pm)
  if [[ $pm == none ]]; then
    warn "no pacman, dnf, apt, or zypper — cannot auto-install packages"
    local p
    for p in "${pkgs[@]}"; do
      FAILED_PKGS+=("$p")
      MANUAL_NOTES+=("$(devapps_pkg_manual_hint "$p")")
    done
    return 0
  fi

  local repo=() aur=() p resolved cmd
  for p in "${pkgs[@]}"; do
    cmd=$(devapps_provides_cmd "$p")
    if [[ -n $cmd ]] && devapps_cmd_path "$cmd" >/dev/null; then
      INSTALLED_PKGS+=("$p (already: $cmd)")
      continue
    fi
    resolved=""
    local cand
    while IFS= read -r cand; do
      [[ -z $cand ]] && continue
      if devapps_pkg_installed_pm "$pm" "$cand"; then
        INSTALLED_PKGS+=("$cand (already)")
        resolved=$cand
        break
      fi
    done < <(devapps_map_pkg "$pm" "$p")
    [[ -n $resolved ]] && continue
    while IFS= read -r cand; do
      [[ -z $cand ]] && continue
      if devapps_pkg_available "$pm" "$cand"; then
        resolved=$cand
        break
      fi
    done < <(devapps_map_pkg "$pm" "$p")
    if [[ -n $resolved ]]; then
      repo+=("$resolved")
    elif [[ $pm == pacman ]]; then
      aur+=("$p")
    else
      FAILED_PKGS+=("$p")
      MANUAL_NOTES+=("$(devapps_pkg_manual_hint "$p")")
    fi
  done

  if ((${#repo[@]})); then
    info "$pm: ${repo[*]}"
    if (( DRY_RUN )); then
      INSTALLED_PKGS+=("${repo[@]}")
    elif pm_install_batch "$pm" "${repo[@]}"; then
      INSTALLED_PKGS+=("${repo[@]}")
    else
      warn "$pm failed for: ${repo[*]}"
      FAILED_PKGS+=("${repo[@]}")
    fi
  fi

  if ((${#aur[@]})); then
    if ! command -v paru >/dev/null 2>&1; then
      warn "paru not installed — AUR packages need a manual install: ${aur[*]}"
      local a
      for a in "${aur[@]}"; do
        FAILED_PKGS+=("$a")
        MANUAL_NOTES+=("$(devapps_pkg_manual_hint "$a")")
      done
    elif (( DRY_RUN )); then
      info "dry-run paru: ${aur[*]}"
      INSTALLED_PKGS+=("${aur[@]}")
    else
      info "paru: ${aur[*]}"
      if paru -S --needed -- "${aur[@]}"; then
        INSTALLED_PKGS+=("${aur[@]}")
      else
        warn "paru failed for: ${aur[*]}"
        FAILED_PKGS+=("${aur[@]}")
      fi
    fi
  fi
}

devapps_install_nvm() {
  local ver=$1
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s $nvm_dir/nvm.sh ]]; then
    INSTALLED_PKGS+=("nvm (already)")
    return 0
  fi
  [[ -n $ver ]] || ver="0.40.6"
  local url="https://raw.githubusercontent.com/nvm-sh/nvm/v${ver}/install.sh"
  info "installing nvm v$ver"
  if (( DRY_RUN )); then
    INSTALLED_PKGS+=("nvm v$ver")
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "$url" | bash; then
      INSTALLED_PKGS+=("nvm v$ver")
    else
      FAILED_PKGS+=("nvm")
      MANUAL_NOTES+=("nvm — curl -o- $url | bash")
      return 1
    fi
  else
    FAILED_PKGS+=("nvm")
    MANUAL_NOTES+=("nvm — install curl, then: curl -o- $url | bash")
    return 1
  fi
}

devapps_use_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [[ -s $NVM_DIR/nvm.sh ]] && . "$NVM_DIR/nvm.sh"
}

devapps_restore() {
  local snap=$1
  local file="$snap/packages/dev-apps.json"
  [[ -f $file ]] || { warn "no packages/dev-apps.json in this snapshot"; return 0; }

  INSTALLED_PKGS=()
  FAILED_PKGS=()
  MANUAL_NOTES=()

  info "development apps from snapshot"

  local pkgs
  pkgs=$(python3 - "$file" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
seen = []
for a in doc.get("apps") or []:
    for p in a.get("packages") or []:
        if p not in seen:
            seen.append(p)
print(" ".join(seen))
PY
)
  # shellcheck disable=SC2086
  devapps_try_packages $pkgs

  local extra_notes
  extra_notes=$(python3 - "$file" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for a in doc.get("apps") or []:
    n = (a.get("note") or "").strip()
    if n:
        print(n)
PY
)
  while IFS= read -r note; do
    [[ -n $note ]] && MANUAL_NOTES+=("$note")
  done <<< "$extra_notes"

  local nvm_ver nvm_default nvm_nodes py_vers
  nvm_ver=$(python3 -c "import json,sys; n=json.load(open(sys.argv[1])).get('nvm') or {}; print(n.get('version') or '')" "$file")
  nvm_default=$(python3 -c "import json,sys; n=json.load(open(sys.argv[1])).get('nvm') or {}; print(n.get('default') or '')" "$file")
  nvm_nodes=$(python3 -c "import json,sys; n=json.load(open(sys.argv[1])).get('nvm') or {}; print(' '.join(n.get('installed') or []))" "$file")
  py_vers=$(python3 -c "import json,sys; p=json.load(open(sys.argv[1])).get('pyenv') or {}; print(' '.join(p.get('installed') or []))" "$file")

  if [[ -n $nvm_ver || -n $nvm_nodes ]]; then
    if devapps_install_nvm "${nvm_ver:-0.40.6}"; then
      if (( ! DRY_RUN )); then
        devapps_use_nvm
        local nv
        for nv in $nvm_nodes; do
          nv=${nv#v}
          info "nvm install $nv"
          nvm install "$nv" || { FAILED_PKGS+=("node $nv"); MANUAL_NOTES+=("Node $nv — nvm install $nv"); }
        done
        if [[ -n $nvm_default ]]; then
          nvm alias default "$nvm_default" || true
        elif [[ -n $nvm_nodes ]]; then
          nvm alias default "${nvm_nodes##* }" || true
        fi
      fi
    fi
  fi

  if [[ -n $py_vers ]]; then
    export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
    if ! command -v pyenv >/dev/null 2>&1 && [[ ! -x $PYENV_ROOT/bin/pyenv ]]; then
      info "installing pyenv from GitHub"
      if (( DRY_RUN )); then
        INSTALLED_PKGS+=("pyenv (git)")
      elif command -v git >/dev/null 2>&1; then
        git clone --depth 1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT" \
          && INSTALLED_PKGS+=("pyenv (git)") \
          || { FAILED_PKGS+=("pyenv"); MANUAL_NOTES+=("pyenv — git clone https://github.com/pyenv/pyenv.git ~/.pyenv"); }
      else
        FAILED_PKGS+=("pyenv")
        MANUAL_NOTES+=("pyenv — install git, then: git clone https://github.com/pyenv/pyenv.git ~/.pyenv")
      fi
    fi
    [[ -x $PYENV_ROOT/bin/pyenv ]] && PATH="$PYENV_ROOT/bin:$PATH"
    if (( ! DRY_RUN )) && command -v pyenv >/dev/null 2>&1; then
      eval "$(pyenv init -)" 2>/dev/null || true
      local pv
      for pv in $py_vers; do
        info "pyenv install $pv"
        pyenv install -s "$pv" || { FAILED_PKGS+=("python $pv"); MANUAL_NOTES+=("Python $pv — pyenv install $pv"); }
      done
      pyenv global "${py_vers%% *}" 2>/dev/null || true
    elif (( DRY_RUN )); then
      info "dry-run pyenv install $py_vers"
    fi
  fi

  local npm_globals
  npm_globals=$(python3 -c "import json,sys; print(' '.join(sorted({x.split('@')[0] for x in (json.load(open(sys.argv[1])).get('npm_globals') or [])})))" "$file")
  if [[ -n $npm_globals ]]; then
    if (( DRY_RUN )); then
      info "dry-run npm -g install $npm_globals"
    else
      devapps_use_nvm
      if command -v npm >/dev/null 2>&1; then
        info "npm -g install $npm_globals"
        # shellcheck disable=SC2086
        npm install -g $npm_globals || { FAILED_PKGS+=("npm globals"); MANUAL_NOTES+=("npm -g install $npm_globals"); }
      else
        MANUAL_NOTES+=("npm globals ($npm_globals) — install Node/nvm first, then: npm i -g $npm_globals")
      fi
    fi
  fi

  printf '\n%sDevelopment apps%s\n' "$C_BOLD" "$C_RESET"
  if ((${#INSTALLED_PKGS[@]})); then
    printf '  %sinstalled%s  %s\n' "$C_GRN" "$C_RESET" "${INSTALLED_PKGS[*]}"
  fi
  if ((${#FAILED_PKGS[@]})); then
    printf '  %sfailed%s     %s\n' "$C_RED" "$C_RESET" "${FAILED_PKGS[*]}"
  fi
  if ((${#MANUAL_NOTES[@]})); then
    printf '\n  %sStill needs you%s\n' "$C_YEL" "$C_RESET"
    local n seen=" "
    local note
    for note in "${MANUAL_NOTES[@]}"; do
      [[ $seen == *" |$note| "* ]] && continue
      seen+="|$note| "
      printf '    • %s\n' "$note"
    done
  fi
  if (( ! DRY_RUN )) && command -v docker >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
    local me
    me=$(id -un)
    if ! id -nG "$me" | grep -qw docker; then
      sudo usermod -aG docker "$me" 2>/dev/null || true
      MANUAL_NOTES+=("docker group — log out and back in (or: newgrp docker)")
    fi
  fi
}
