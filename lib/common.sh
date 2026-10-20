#!/usr/bin/env bash
# Shared helpers for bootstrap.sh, modules/*, checks/* and tools/*.
# Keep this file bash-3.2 compatible: tools/ may run on macOS.

[[ -n "${OPS_COMMON_LOADED:-}" ]] && return 0
OPS_COMMON_LOADED=1

OPS_ROOT="${OPS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export OPS_ROOT

# Never let apt/dpkg/needrestart stop and ask questions.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

_ts()    { date '+%H:%M:%S'; }
info()   { printf '%s[%s]%s %s\n' "$C_BLUE" "$(_ts)" "$C_RESET" "$*"; }
ok()     { printf '%s[%s] OK%s   %s\n' "$C_GREEN" "$(_ts)" "$C_RESET" "$*"; }
warn()   { printf '%s[%s] WARN%s %s\n' "$C_YELLOW" "$(_ts)" "$C_RESET" "$*" >&2; }
die()    { printf '%s[%s] FAIL%s %s\n' "$C_RED" "$(_ts)" "$C_RESET" "$*" >&2; exit 1; }
section() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

is_true() {
  case "${1:-}" in
    1|y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This must run as root (use sudo)."
}

require_supported_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Unsupported OS '${ID:-unknown}'. Only Ubuntu and Debian are supported." ;;
  esac
  export OS_ID="$ID" OS_CODENAME="${VERSION_CODENAME:-}" OS_VERSION="${VERSION_ID:-}"
}

# Loads config/default.env, then the file in $OPS_CONFIG (if set).
# Precedence: config file > environment variables > defaults.
load_config() {
  [[ -n "${OPS_CONFIG_LOADED:-}" ]] && return 0
  set -a
  # shellcheck source=../config/default.env
  . "$OPS_ROOT/config/default.env"
  if [[ -n "${OPS_CONFIG:-}" ]]; then
    [[ -f "$OPS_CONFIG" ]] || die "Config file not found: $OPS_CONFIG"
    # shellcheck disable=SC1090
    . "$OPS_CONFIG"
  fi
  set +a
  export OPS_CONFIG_LOADED=1
}

# apt-get wrapper: waits for the dpkg lock (cloud-init / unattended-upgrades
# often hold it on first boot) and keeps existing config files on upgrade.
apt_get() {
  apt-get -y -q \
    -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

apt_install() { apt_get install "$@"; }

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

user_exists() { id "$1" >/dev/null 2>&1; }

user_home() { getent passwd "$1" | cut -d: -f6; }

# The port(s) sshd is configured to listen on right now.
current_ssh_ports() {
  mkdir -p /run/sshd
  sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -u
}

# Write a file only if its content changed. Returns 0 if written, 1 if unchanged.
write_if_changed() {
  local dest="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  install -m "$mode" -D "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}
