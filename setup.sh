#!/usr/bin/env bash
# Fallback menu (whiptail) for ops-scripts: pick modules, tools and settings from
# checklists, then run them. The main UI is ./ops; it opens this one by itself
# when the UI binary can't be built or downloaded.
set -euo pipefail

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPS_ROOT
# shellcheck source=lib/common.sh
. "$OPS_ROOT/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 [-c CONFIG]

  -c, --config FILE   Start from this config (its choices are pre-selected)

Arrow keys move, Space toggles a checkbox, Tab switches to the buttons, Enter confirms.
For non-interactive runs (scripts, user-data, Terraform) use bootstrap.sh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config) [[ -n "${2:-}" ]] || die "--config needs a file"
                 OPS_CONFIG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
                 export OPS_CONFIG; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "Unknown option: $1" ;;
  esac
done

[[ -t 0 && -t 1 ]] || die "setup.sh needs an interactive terminal. Use bootstrap.sh for scripts."
require_root
require_supported_os
load_config
command -v whiptail >/dev/null || { info "Installing whiptail"; ensure_packages whiptail; }

BASE_CONFIG="${OPS_CONFIG:-}"
CHOICES_FILE="$(mktemp)"
trap 'rm -f "$CHOICES_FILE"' EXIT

# --- whiptail helpers --------------------------------------------------------
read -r ROWS COLS < <(stty size 2>/dev/null || echo "24 80")
H=$(( ROWS > 30 ? 26 : ROWS - 3 ))
W=$(( COLS > 100 ? 92 : COLS - 6 ))
LH=$(( H - 9 ))

# Runs whiptail and prints the selection on stdout. Non-zero on Cancel/Esc.
wt() {
  whiptail --title " ops-scripts - $(hostname) " --backtitle "ops-scripts - server preparation" \
    "$@" 3>&1 1>&2 2>&3
}

pause() { echo; read -rp "Press Enter to return to the menu... " _; }

module_files() { printf '%s\n' "$OPS_ROOT"/modules/*.sh; }
module_name()  { local b; b="$(basename "$1" .sh)"; echo "${b#*-}"; }
module_desc()  { sed -n 2p "$1" | sed 's/^# *//' | cut -c1-$(( W - 28 )); }
enable_var()   { echo "ENABLE_$(echo "$1" | tr 'a-z-' 'A-Z_')"; }
in_words()     { [[ " $2 " == *" $1 "* ]]; }

# --- Tool catalogs (name|description) ------------------------------------------
CLI_CATALOG="ripgrep|rg: very fast grep
fd-find|fd: simple, fast find
fzf|fuzzy finder (Ctrl-R history, Ctrl-T files)
bat|cat with syntax highlighting
eza|modern ls (ll and lt aliases)
zoxide|smarter cd: z <part-of-dir>
btop|CPU / memory / disk / network monitor
ncdu|find what is using disk space
duf|disk usage overview
tealdeer|tldr: short practical command examples
git-delta|readable git diffs
httpie|http: friendly curl for APIs
iftop|bandwidth per connection
nethogs|bandwidth per process
iotop-c|disk I/O per process
sysstat|sar / iostat performance history
strace|trace system calls (debugging)
lnav|log file viewer with search and filters
plocate|locate: instant file name search"

DEV_CATALOG="git|git + git-lfs with sane defaults (name/email from settings)
lazygit|terminal UI for git
lazydocker|terminal UI for Docker containers and logs
neovim|latest Neovim from the official release
lazyvim|LazyVim config for ADMIN_USER (adds Neovim)
herdr|terminal multiplexer for coding agents"

# Checklist over a catalog; stores the chosen names (space separated) in VAR.
pick_from_catalog() { # VAR catalog prompt
  local var="$1" catalog="$2" prompt="$3" items=() name desc state sel n
  while IFS='|' read -r name desc; do
    state=OFF; in_words "$name" "${!var}" && state=ON
    items+=("$name" "$desc" "$state")
  done <<< "$catalog"
  # Keep custom entries from a config file that aren't in the catalog.
  for n in ${!var}; do
    grep -q "^$n|" <<< "$catalog" || items+=("$n" "(from your config)" ON)
  done
  sel=$(wt --separate-output --checklist "$prompt\n\nSpace = toggle - Enter = confirm" \
          "$H" "$W" "$LH" "${items[@]}") || return 1
  printf -v "$var" '%s' "$(echo "$sel" | tr '\n' ' ' | sed 's/ *$//')"
}

# --- Settings ----------------------------------------------------------------
# key|label|help|show-when-module (empty = always)
SETTINGS="ADMIN_USER|Login user|The user you SSH in as (ubuntu on Ubuntu AMIs, admin on Debian).|
TIMEZONE|Timezone|e.g. UTC, Asia/Riyadh, Europe/London.|system-update
HOSTNAME_FQDN|Hostname|Full hostname, e.g. web1.acme.com. Empty = leave as is.|system-update
SWAP_SIZE|Swap size|auto (2G if RAM < 4G), 0 for none, or a size like 1G / 4G.|swap
FIREWALL_ALLOW_HTTP|Open HTTP 80|yes / no|firewall
FIREWALL_ALLOW_HTTPS|Open HTTPS 443|yes / no|firewall
FIREWALL_EXTRA_PORTS|Extra ports|Space separated, e.g. 8080/tcp 51820/udp. Empty = none.|firewall
SSH_ALLOW_FROM|SSH allowed from|A CIDR like 203.0.113.4/32. Empty = anywhere (the security group still applies).|firewall
SSH_PORT|SSH port|Keep 22 unless you have a reason. If you change it, open it in the EC2 security group first.|ssh-hardening
AUTO_UPDATES_REBOOT|Auto reboot|yes = unattended-upgrades may reboot at night when a kernel update needs it.|auto-updates
GIT_USER_NAME|Git name|git config user.name for the login user.|dev-tools
GIT_USER_EMAIL|Git email|git config user.email for the login user.|dev-tools
CERTBOT_DOMAINS|HTTPS domains|Space separated, e.g. acme.com www.acme.com. DNS must already point here. Empty = skip.|nginx
CERTBOT_EMAIL|HTTPS email|Let's Encrypt expiry notices go here.|nginx
TAILSCALE_AUTHKEY|Auth key|tskey-auth-... from the Tailscale admin console > Settings > Keys. Empty = log in later with 'sudo tailscale up'. Never written to saved config files.|tailscale
TAILSCALE_HOSTNAME|Tailnet name|Name in your tailnet, e.g. acme-web. Empty = system hostname.|tailscale
TAILSCALE_SSH|Tailscale SSH|yes = SSH over Tailscale with your tailnet identity (no keys needed).|tailscale
TAILSCALE_SSH_ONLY|SSH only via TS|yes = close public SSH once Tailscale is connected. Test Tailscale SSH works first!|tailscale
REBOOT_IF_REQUIRED|Reboot at end|yes = reboot after setup if updates need it.|"

# Settings that are secrets: masked on screen and never written to saved files.
SECRET_SETTINGS=" TAILSCALE_AUTHKEY "
is_secret() { [[ "$SECRET_SETTINGS" == *" $1 "* ]]; }
show_value() { # key
  if is_secret "$1"; then [[ -n "${!1}" ]] && echo "(set)" || echo "(empty)"
  else echo "${!1:-(empty)}"; fi
}

module_on() { local v; v="$(enable_var "$1")"; is_true "${!v:-no}"; }

validate_setting() { # key value -> error message on stdout, empty if OK
  case "$1" in
    ADMIN_USER) user_exists "$2" || echo "User '$2' does not exist on this server." ;;
    TIMEZONE)   [[ -f "/usr/share/zoneinfo/$2" ]] || echo "Unknown timezone '$2'." ;;
    SSH_PORT)   [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 65535 )) || echo "Port must be 1-65535." ;;
    SWAP_SIZE)  [[ "$2" =~ ^(auto|0|[0-9]+[MG])$ ]] || echo "Use auto, 0, or a size like 2G." ;;
    TAILSCALE_AUTHKEY) [[ -z "$2" || "$2" == tskey-* ]] || echo "Auth keys start with tskey-." ;;
    FIREWALL_ALLOW_HTTP|FIREWALL_ALLOW_HTTPS|AUTO_UPDATES_REBOOT|REBOOT_IF_REQUIRED|TAILSCALE_SSH|TAILSCALE_SSH_ONLY)
                [[ "$2" =~ ^(yes|no)$ ]] || echo "Use yes or no." ;;
  esac
}

edit_settings() {
  local key label help when items choice new err
  while true; do
    items=()
    while IFS='|' read -r key label help when; do
      [[ -z "$when" ]] || module_on "$when" || continue
      items+=("$key" "$(printf '%-17s %s' "$label" "$(show_value "$key")")")
    done <<< "$SETTINGS"
    items+=("CONTINUE" "> Review and run")
    choice=$(wt --ok-button "Select" --cancel-button "Back" --menu \
      "Settings for the selected modules. Select one to change it, or CONTINUE." \
      "$H" "$W" "$LH" "${items[@]}") || return 1
    [[ "$choice" == "CONTINUE" ]] && return 0
    help="$(grep "^$choice|" <<< "$SETTINGS" | cut -d'|' -f3)"
    if is_secret "$choice"; then
      new=$(wt --passwordbox "$choice\n\n$help" 13 "$W" "${!choice}") || continue
    else
      new=$(wt --inputbox "$choice\n\n$help" 12 "$W" "${!choice}") || continue
    fi
    err="$(validate_setting "$choice" "$new")"
    if [[ -n "$err" ]]; then wt --msgbox "$err" 8 "$W"; continue; fi
    printf -v "$choice" '%s' "$new"
  done
}

# --- Saving choices ----------------------------------------------------------
kv() { printf "%s='%s'\n" "$1" "${!1//\'/\'\\\'\'}"; }

write_choices() { # file [save] - "save" leaves secrets out
  local f key
  {
    echo "# Generated by setup.sh on $(date -Is) on $(hostname)"
    if [[ -n "$BASE_CONFIG" ]]; then
      echo "# Based on $BASE_CONFIG"
      cat "$BASE_CONFIG"
      echo
      echo "# --- Choices made in setup.sh (these win) ---"
    fi
    for f in $(module_files); do kv "$(enable_var "$(module_name "$f")")"; done
    kv CLI_TOOLS
    kv DEV_TOOLS
    while IFS='|' read -r key _; do
      if is_secret "$key" && [[ "${2:-}" == save ]]; then
        # Only a comment: an empty assignment would override the env var at run time.
        echo "# $key is a secret and not saved. Pass it when you run: sudo $key=... ./bootstrap.sh -c <this file>"
      else
        kv "$key"
      fi
    done <<< "$SETTINGS"
  } > "$1" || return 1
  chmod 600 "$1"
}

# Runs bootstrap.sh with the current choices.
run_bootstrap() {
  write_choices "$CHOICES_FILE"
  clear
  env -u OPS_CONFIG_LOADED bash "$OPS_ROOT/bootstrap.sh" -c "$CHOICES_FILE" "$@" || true
  pause
}

# --- Screens -----------------------------------------------------------------
pick_modules() {
  local items=() f n state sel
  for f in $(module_files); do
    n="$(module_name "$f")"
    state=OFF; module_on "$n" && state=ON
    items+=("$n" "$(module_desc "$f")" "$state")
  done
  sel=$(wt --separate-output --checklist \
    "Choose what to set up on this server.\n\nSpace = toggle - Enter = confirm" \
    "$H" "$W" "$LH" "${items[@]}") || return 1
  for f in $(module_files); do
    n="$(module_name "$f")"
    if grep -qx "$n" <<< "$sel"; then printf -v "$(enable_var "$n")" yes
    else printf -v "$(enable_var "$n")" no; fi
  done
}

review() {
  local f n mods="" text cur_ports
  for f in $(module_files); do
    n="$(module_name "$f")"; module_on "$n" && mods+="  * $n\n"
  done
  [[ -n "$mods" ]] || { wt --msgbox "No modules selected." 8 40; return 1; }

  text="Modules to run:\n$mods"
  module_on cli-tools && text+="\nCLI tools: ${CLI_TOOLS:-none}\n"
  module_on dev-tools && text+="\nDev tools: ${DEV_TOOLS:-none}\n"
  text+="\nLogin user: $ADMIN_USER"
  module_on system-update && text+="\nTimezone: $TIMEZONE   Hostname: ${HOSTNAME_FQDN:-(unchanged)}"
  module_on nginx && text+="\nHTTPS domains: ${CERTBOT_DOMAINS:-(none yet)}"
  if module_on tailscale; then
    if [[ -n "$TAILSCALE_AUTHKEY" ]]; then text+="\nTailscale: install and connect (auth key set)"
    else text+="\nTailscale: install only - log in afterwards with 'sudo tailscale up'"; fi
    is_true "$TAILSCALE_SSH_ONLY" && text+="\n\n!! Public SSH will close once Tailscale is connected. Have Tailscale on your own device first."
  fi

  if module_on ssh-hardening; then
    cur_ports="$(current_ssh_ports | tr '\n' ' ')"
    if [[ " $cur_ports " != *" $SSH_PORT "* ]]; then
      text+="\n\n!! SSH moves from port ${cur_ports% } to $SSH_PORT. Open $SSH_PORT in the EC2 security group BEFORE running."
    fi
    if [[ ! -s "$(user_home "$ADMIN_USER")/.ssh/authorized_keys" ]]; then
      text+="\n\n!! $ADMIN_USER has no SSH key, so ssh-hardening will refuse to run."
    fi
  fi
  wt --yes-button "Run now" --no-button "Back" --yesno "$text" "$H" "$W"
}

offer_save() {
  local path
  wt --yesno "Save these choices to a config file?\n\nYou can reuse it later with:\n  sudo ./bootstrap.sh -c <file>\n  sudo ./setup.sh -c <file>" 13 "$W" || return 0
  path=$(wt --inputbox "Save to:" 9 "$W" "$OPS_ROOT/config/saved.local.env") || return 0
  [[ -n "$path" ]] || return 0
  if mkdir -p "$(dirname "$path")" 2>/dev/null && write_choices "$path" save 2>/dev/null; then
    wt --msgbox "Saved to $path" 8 "$W"
  else
    wt --msgbox "Could not write $path. Continuing without saving." 8 "$W"
  fi
}

guided_setup() {
  pick_modules || return 0
  if module_on cli-tools; then
    pick_from_catalog CLI_TOOLS "$CLI_CATALOG" "Which CLI tools?" || return 0
  fi
  if module_on dev-tools; then
    pick_from_catalog DEV_TOOLS "$DEV_CATALOG" "Which dev tools? (installed for $ADMIN_USER)" || return 0
  fi
  while true; do
    edit_settings || return 0
    review && break
  done
  offer_save
  run_bootstrap
}

single_module() {
  local items=() f sel
  for f in $(module_files); do items+=("$(module_name "$f")" "$(module_desc "$f")"); done
  sel=$(wt --menu "Run one module now (uses the current settings):" "$H" "$W" "$LH" "${items[@]}") || return 0
  run_bootstrap --only "$sel"
}

generate_secret() {
  local kind value cmd
  kind=$(wt --menu "What do you need?" 16 "$W" 6 \
    app   "App secret / API key / JWT secret (64 hex chars)" \
    db    "Database password (48 hex chars, safe in URLs)" \
    url   "URL-safe secret (base64url, 43 chars)" \
    human "Password you can type (24 letters and digits)" \
    ssh   "How to create an SSH / EC2 key pair") || return 0
  case "$kind" in
    app)   cmd="openssl rand -hex 32" ;;
    db)    cmd="openssl rand -hex 24" ;;
    url)   cmd="openssl rand -base64 32 | tr '+/' '-_' | tr -d '='" ;;
    human) cmd="openssl rand -base64 18 | tr -d '+/='" ;;
    ssh)
      wt --msgbox "Create the key on YOUR computer, not on the server:\n\n  ssh-keygen -t ed25519 -f ~/.ssh/acme-ec2 -C acme-ec2\n\nThen import ~/.ssh/acme-ec2.pub in the AWS console:\nEC2 > Key Pairs > Actions > Import key pair.\n\nSee 'EC2 key pairs' in README.md for details." 16 "$W"
      return 0 ;;
  esac
  value="$(bash -c "$cmd")"
  clear
  printf '\n  %s\n\n  Generated with:  %s\n\n  Copy it now; it is not saved anywhere.\n' "$value" "$cmd"
  pause
}

show_status() {
  local out
  out="$(mktemp)"
  {
    echo "Config: ${BASE_CONFIG:-defaults only}"
    echo
    printf '%-20s %s\n' MODULE ENABLED
    for f in $(module_files); do
      n="$(module_name "$f")"; v="$(enable_var "$n")"
      printf '%-20s %s\n' "$n" "${!v:-no}"
    done
    echo
    echo "CLI_TOOLS: $CLI_TOOLS"
    echo "DEV_TOOLS: $DEV_TOOLS"
    echo
    while IFS='|' read -r key label _; do printf '%-22s %s\n' "$key" "$(show_value "$key")"; done <<< "$SETTINGS"
  } > "$out"
  wt --scrolltext --textbox "$out" "$H" "$W" || true
  rm -f "$out"
}

# --- Main menu ---------------------------------------------------------------
while true; do
  choice=$(wt --cancel-button "Exit" --menu "What do you want to do?" 17 "$W" 7 \
    setup  "Guided setup: choose modules, tools, settings > run" \
    module "Run a single module" \
    audit  "Security audit (read-only, changes nothing)" \
    secret "Generate a secret or password" \
    status "Show current choices" \
    exit   "Exit") || { clear; exit 0; }
  case "$choice" in
    setup)  guided_setup ;;
    module) single_module ;;
    audit)  clear; bash "$OPS_ROOT/checks/audit.sh" || true; pause ;;
    secret) generate_secret ;;
    status) show_status ;;
    exit)   clear; exit 0 ;;
  esac
done
