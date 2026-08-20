# shellcheck shell=bash
# sourced by distrohop — package-manager abstraction (pacman/dnf/apt/zypper)
# shellcheck disable=SC2034

pm_detect() {
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' pacman
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s\n' dnf
  elif command -v zypper >/dev/null 2>&1; then
    printf '%s\n' zypper
  elif command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' apt
  else
    printf '%s\n' none
  fi
}

pm_pkg_installed() {
  local pm=$1 p=$2
  case $pm in
    pacman) pacman -Q "$p" >/dev/null 2>&1 ;;
    dnf|zypper) rpm -q "$p" >/dev/null 2>&1 ;;
    apt) dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' ;;
    *) return 1 ;;
  esac
}

pm_pkg_available() {
  local pm=$1 p=$2
  case $pm in
    pacman) pacman -Si "$p" >/dev/null 2>&1 ;;
    dnf) dnf list --available "$p" >/dev/null 2>&1 ;;
    # best-effort: unverified against a real zypper install
    zypper) zypper --non-interactive info "$p" 2>/dev/null | grep -qi '^Repository *:' ;;
    apt) apt-cache show "$p" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pm_install_batch() {
  local pm=$1; shift
  local pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  case $pm in
    pacman) sudo pacman -S --needed -- "${pkgs[@]}" ;;
    dnf) sudo dnf install -y -- "${pkgs[@]}" ;;
    # best-effort: unverified against a real zypper install
    zypper) sudo zypper --non-interactive install --auto-agree-with-licenses -- "${pkgs[@]}" ;;
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${pkgs[@]}"
      ;;
    *) return 1 ;;
  esac
}

# "explicitly installed, not pulled in as a dependency" package list per distro.
pm_explicit_packages() {
  local pm=$1
  case $pm in
    pacman) pacman -Qqe 2>/dev/null ;;
    # dnf5 (Fedora 41+) is usually aliased to the `dnf` binary and accepts
    # the same repoquery flags; unverified on a real dnf5-only host.
    dnf) dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null ;;
    apt) apt-mark showmanual 2>/dev/null ;;
    zypper)
      # best-effort: filters against zypper's auto-installed marker file,
      # unverified across zypper versions — falls back to the full list.
      if [[ -r /var/lib/zypp/AutoInstalled ]]; then
        comm -23 <(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u) \
                  <(sort -u /var/lib/zypp/AutoInstalled)
      else
        warn "zypper: no /var/lib/zypp/AutoInstalled — can't filter dependencies, dumping full installed list"
        rpm -qa --qf '%{NAME}\n' 2>/dev/null
      fi
      ;;
    *) return 1 ;;
  esac
}

# Arch snapshot name → candidates on this distro (first match in repos wins).
pm_map_pkg() {
  local pm=$1 pkg=$2
  case $pm:$pkg in
    *:cursor-bin) ;;
    *:postman-bin) ;;
    *:android-studio) ;;
    *:supabase-bin) ;;
    pacman:*) printf '%s\n' "$pkg" ;;
    apt:github-cli|dnf:github-cli|zypper:github-cli) printf '%s\n' gh ;;
    apt:docker) printf '%s\n' docker.io docker-ce docker ;;
    dnf:docker) printf '%s\n' docker docker-ce moby-engine ;;
    zypper:docker) printf '%s\n' docker ;;
    apt:docker-compose) printf '%s\n' docker-compose-plugin docker-compose-v2 docker-compose ;;
    dnf:docker-compose) printf '%s\n' docker-compose docker-compose-plugin ;;
    zypper:docker-compose) printf '%s\n' docker-compose ;;
    apt:docker-buildx) printf '%s\n' docker-buildx docker-buildx-plugin ;;
    dnf:docker-buildx) printf '%s\n' docker-buildx docker-buildx-plugin ;;
    zypper:docker-buildx) printf '%s\n' docker-buildx ;;
    apt:visual-studio-code-bin|dnf:visual-studio-code-bin|zypper:visual-studio-code-bin) printf '%s\n' code ;;
    apt:jdk-openjdk) printf '%s\n' default-jdk openjdk-21-jdk openjdk-17-jdk ;;
    dnf:jdk-openjdk) printf '%s\n' java-21-openjdk-devel java-17-openjdk-devel java-latest-openjdk-devel ;;
    zypper:jdk-openjdk) printf '%s\n' java-21-openjdk-devel java-17-openjdk-devel ;;
    apt:dbeaver|dnf:dbeaver|zypper:dbeaver) printf '%s\n' dbeaver dbeaver-ce ;;
    *) printf '%s\n' "$pkg" ;;
  esac
}
