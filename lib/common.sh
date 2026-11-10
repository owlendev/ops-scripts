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
err()    { printf '%s[%s] FAIL%s %s\n' "$C_RED" "$(_ts)" "$C_RESET" "$*" >&2; }  # like die, but carries on
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

# True if apt can install the package on this OS version.
apt_available() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2 }' | grep -qv '^(none)$'
}

# Install whichever of the given packages are missing.
ensure_packages() {
  local p missing=()
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  apt_get update
  apt_install "${missing[@]}"
}

# Debian/Ubuntu rename some binaries to avoid clashes; add the usual names.
link_distro_names() {
  [[ -x /usr/bin/fdfind && ! -e /usr/local/bin/fd ]]  && ln -s /usr/bin/fdfind /usr/local/bin/fd
  [[ -x /usr/bin/batcat && ! -e /usr/local/bin/bat ]] && ln -s /usr/bin/batcat /usr/local/bin/bat
  return 0
}

# Latest release of a GitHub repo (owner/name) as JSON.
# Set GITHUB_TOKEN if you hit the API rate limit (60 requests/hour per IP).
gh_latest_release() {
  local auth=() out code
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  if ! out="$(curl -sSL ${auth[@]+"${auth[@]}"} -w '\n%{http_code}' \
                "https://api.github.com/repos/$1/releases/latest" 2>&1)"; then
    die "Cannot reach api.github.com for $1: $(tail -1 <<< "$out")"
  fi
  code="${out##*$'\n'}"
  case "$code" in
    200)     printf '%s\n' "${out%$'\n'*}" ;;
    403|429) die "GitHub API rate limit reached for $1 (60 requests/hour per IP without GITHUB_TOKEN)" ;;
    404)     die "No releases found for $1" ;;
    *)       die "GitHub API returned HTTP $code for $1" ;;
  esac
}

# Download one asset of a release and verify its SHA-256 checksum.
gh_download_asset() { # release_json asset_name dest
  local url digest
  url=$(jq -r --arg n "$2" '.assets[] | select(.name == $n) | .browser_download_url' <<< "$1")
  [[ -n "$url" ]] || die "Release asset '$2' not found"
  digest=$(jq -r --arg n "$2" '.assets[] | select(.name == $n) | .digest // empty' <<< "$1")
  curl -fsSL "$url" -o "$3" || die "Download of $2 failed (network problem?)"
  if [[ "$digest" == sha256:* ]]; then
    echo "${digest#sha256:}  $3" | sha256sum -c --quiet - || die "Checksum mismatch for $2"
  else
    warn "No checksum published for $2; not verified"
  fi
}

# --- Tool results --------------------------------------------------------------
# cli-tools and dev-tools record each tool's result here; checks/audit.sh re-checks
# them and checks/fix.sh reinstalls them. Columns (tab separated):
#   name  kind(cli|dev)  status(ok|failed|skipped)  user  detail(version or reason)  hint  time
TOOLS_STATE=/var/lib/ops-scripts/tools.tsv

_one_line() { tr '\t\n' '  ' <<< "$1" | sed 's/  *$//'; }

tool_record() { # name kind status user detail hint
  local f
  mkdir -p "$(dirname "$TOOLS_STATE")"
  f="$(mktemp)"
  [[ -f "$TOOLS_STATE" ]] && awk -F'\t' -v n="$1" '$1 != n' "$TOOLS_STATE" > "$f"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(_one_line "$5")" "$(_one_line "$6")" \
    "$(date '+%Y-%m-%d %H:%M')" >> "$f"
  install -m 0644 "$f" "$TOOLS_STATE"
  rm -f "$f"
}

# The command a dev tool installs.
dev_tool_cmd() { case "$1" in neovim|lazyvim) echo nvim ;; *) echo "$1" ;; esac; }

# dev_tool_works NAME USER: prints the version if the tool runs for USER (in a
# login shell, as they'd use it), otherwise prints why not and returns 1.
dev_tool_works() {
  local t="$1" u="$2" c out home runner=()
  if user_exists "$u"; then runner=(sudo -u "$u" -H); else u=root; fi
  if [[ "$t" == lazyvim ]]; then
    home="$(user_home "$u")"
    [[ -d "$home/.config/nvim" ]] || { echo "No LazyVim config: $home/.config/nvim is missing"; return 1; }
  fi
  c="$(dev_tool_cmd "$t")"
  # shellcheck disable=SC2016 # $PATH must expand in the user's shell
  if ! out="$(cd / && ${runner[@]+"${runner[@]}"} bash -lc \
       'command -v "$1" >/dev/null || { echo "$1: command not found for $USER (PATH=$PATH)"; exit 127; }
        "$1" --version' _ "$c" 2>&1)"; then
    if [[ "$out" == *"command not found for"* ]] && ! command -v "$c" >/dev/null && [[ ! -e "/usr/local/bin/$c" ]]; then
      echo "$c is missing: not installed, or removed since"
    else
      tail -2 <<< "$out" | tr '\n' ' '; echo
    fi
    return 1
  fi
  # Just the version number when there is one (lazygit prints commit=..., version=...).
  out="$(head -1 <<< "$out")"
  if [[ "$out" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then echo "${BASH_REMATCH[1]}"; else cut -c1-40 <<< "$out"; fi
}

# explain_failure LOG NAME: sets REASON and HINT from what went wrong in LOG.
# shellcheck disable=SC2034 # REASON and HINT are read by the caller
explain_failure() {
  local log="$1" n="$2" last
  last="$(grep -E 'FAIL|^E: |[Ee]rror|not found|Permission denied' "$log" 2>/dev/null | tail -1 \
          | sed -E 's/\x1b\[[0-9;]*m//g; s/^\[[0-9:]+\] FAIL +//')"
  if grep -qi 'rate limit' "$log"; then
    REASON="GitHub API rate limit reached (60 requests/hour per IP)"
    HINT="Wait up to an hour, or add a GitHub token: sudo GITHUB_TOKEN=<token> $OPS_ROOT/checks/fix.sh tool $n"
  elif grep -qiE 'Cannot reach|Could not resolve|Failed to connect|timed out|Temporary failure resolving|Download of .* failed' "$log"; then
    REASON="Couldn't download (no internet, DNS, or the site is down)"
    HINT="Check the internet connection: curl -sI https://github.com | head -1"
  elif grep -q 'Checksum mismatch' "$log"; then
    REASON="Download failed its checksum check (corrupted in transit)"
    HINT="Usually a one-off; if it keeps failing, don't use that release"
  elif grep -qE "Release asset .* not found" "$log"; then
    REASON="This release has no build for this CPU ($(uname -m))"
    HINT="Nothing to fix here; untick $n or wait for a newer release"
  elif grep -q 'No space left' "$log"; then
    REASON="Disk full"
    HINT="Free space first: sudo $OPS_ROOT/checks/fix.sh disk"
  elif grep -qE 'Could not get lock|dpkg was interrupted' "$log"; then
    REASON="The package manager is busy or was interrupted"
    HINT="Run first: sudo dpkg --configure -a"
  elif grep -qE 'Unable to locate package|has no installation candidate' "$log"; then
    REASON="Not packaged for this OS version"
    HINT="Untick $n (remove it from the list)"
  elif grep -q 'Exec format error' "$log"; then
    REASON="The installed binary is for a different CPU"
    HINT="Install it again"
  elif grep -q 'is missing: not installed' "$log"; then
    REASON="The program is missing (not installed, or removed since)"
    HINT="Install it again"
  elif grep -q 'command not found for' "$log"; then
    REASON="Installed, but not in the user's PATH"
    HINT="Open a new SSH session, and check that PATH includes /usr/local/bin"
  elif grep -qE "ADMIN_USER .* does not exist" "$log"; then
    REASON="The login user doesn't exist"
    HINT="Set ADMIN_USER to the user you SSH in as, then retry"
  elif grep -qiE 'Terminated|Killed|cancel' "$log"; then
    REASON="Interrupted before it finished"
    HINT="Run it again and let it finish (LazyVim can take a few minutes)"
  else
    REASON="${last:-Failed; see /var/log/ops-bootstrap.log}"
    HINT="Full output: /var/log/ops-bootstrap.log"
  fi
}

tailscale_online() {
  command -v tailscale >/dev/null &&
    tailscale status --json 2>/dev/null | grep -Eq '"BackendState": *"Running"'
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
