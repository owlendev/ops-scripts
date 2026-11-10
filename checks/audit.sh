#!/usr/bin/env bash
# Read-only security/health report. Changes nothing.
# Checks that can be fixed name a fix from checks/fix.sh.
#
#   sudo checks/audit.sh          human-readable report
#   sudo checks/audit.sh --json   one JSON object per line (used by the ops TUI)
#
# Exit code: 0 = no failures, 1 = at least one FAIL.
set -uo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

PASS=0; WARNS=0; FAILS=0
SECTION=""

json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
  printf '"%s"' "$s"
}

heading() {
  SECTION="$1"
  if (( JSON )); then printf '{"type":"section","title":%s}\n' "$(json_str "$1")"
  else printf '\n%s\n' "$1"; fi
}

# Informational line (no status).
detail() {
  if (( JSON )); then
    printf '{"type":"info","section":%s,"message":%s}\n' "$(json_str "$SECTION")" "$(json_str "$1")"
  else
    printf '  %s\n' "$1"
  fi
}

# check STATUS ID MESSAGE [FIX] [FIX_DESCRIPTION] [RISK]
#   STATUS: pass | warn | fail
#   FIX:    arguments for checks/fix.sh, e.g. "rpcbind" or "docker-allow 443/udp"
#   RISK:   safe (default) | caution (restarts SSH, opens a port, reboots...)
check() {
  local status="$1" id="$2" msg="$3" fix="${4:-}" desc="${5:-}" risk="${6:-safe}"
  case "$status" in
    pass) PASS=$((PASS + 1)); fix="" ;;
    warn) WARNS=$((WARNS + 1)) ;;
    fail) FAILS=$((FAILS + 1)) ;;
  esac
  if (( JSON )); then
    printf '{"type":"check","section":%s,"id":%s,"status":%s,"message":%s,"fix":%s,"fix_desc":%s,"risk":%s}\n' \
      "$(json_str "$SECTION")" "$(json_str "$id")" "$(json_str "$status")" "$(json_str "$msg")" \
      "$(json_str "$fix")" "$(json_str "$desc")" "$(json_str "$risk")"
    return
  fi
  local label color
  case "$status" in
    pass) label=PASS color="$C_GREEN" ;;
    warn) label=WARN color="$C_YELLOW" ;;
    fail) label=FAIL color="$C_RED" ;;
  esac
  printf '  %s%s%s %s\n' "$color" "$label" "$C_RESET" "$msg"
  if [[ -n "$fix" ]]; then
    printf '       fix: %s  ->  sudo %s/checks/fix.sh %s\n' "$desc" "$OPS_ROOT" "$fix"
  elif [[ -n "$desc" ]]; then
    printf '       how: %s\n' "$desc"
  fi
}

(( JSON )) || section "Audit: $(hostname) — $OS_ID $OS_VERSION — kernel $(uname -r)"

# --- System -----------------------------------------------------------------
heading "System"
detail "uptime: $(uptime -p)"
if [[ -f /var/run/reboot-required ]]; then
  check warn system.reboot "Reboot required to finish updates" \
    reboot "Reboot now (you'll be disconnected for about a minute)" caution
else
  check pass system.reboot "No reboot required"
fi

upgradable=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst' || true)
security=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst' | grep -ci security || true)
if (( security > 0 )); then
  check fail system.updates "$security pending security update(s) ($upgradable total)" updates "Install all pending updates"
elif (( upgradable > 0 )); then
  check warn system.updates "$upgradable pending update(s), none security" updates "Install all pending updates"
else
  check pass system.updates "All packages up to date"
fi

if [[ "$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null)" == *'"1"'* ]]; then
  check pass system.auto-updates "Unattended upgrades enabled"
else
  check warn system.auto-updates "Unattended upgrades not enabled" auto-updates "Enable daily automatic security updates"
fi

if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
  check pass system.clock "Clock synchronized (timezone $(timedatectl show -p Timezone --value))"
else
  check warn system.clock "Clock not synchronized" ntp "Turn on network time sync"
fi

root_use=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if (( root_use >= 90 )); then
  check fail system.disk "Root disk ${root_use}% full" disk "Free space: clean apt cache, old packages and journal logs"
elif (( root_use >= 80 )); then
  check warn system.disk "Root disk ${root_use}% full" disk "Free space: clean apt cache, old packages and journal logs"
else
  check pass system.disk "Root disk ${root_use}% used"
fi

detail "memory used: $(free -h | awk '/^Mem:/ {print $3"/"$2}'), swap: $(free -h | awk '/^Swap:/ {print $2}')"

# --- SSH --------------------------------------------------------------------
heading "SSH"
mkdir -p /run/sshd
sshd_conf="$(sshd -T 2>/dev/null)"
sshd_opt() { awk -v k="$1" '$1 == k { print $2; exit }' <<< "$sshd_conf"; }
SSH_FIX_DESC="Apply SSH hardening: keys only, no root login (refuses if you have no SSH key)"

if [[ "$(sshd_opt permitrootlogin)" == "no" ]]; then check pass ssh.root-login "Root login disabled"
else check fail ssh.root-login "Root login allowed (permitrootlogin $(sshd_opt permitrootlogin))" ssh-hardening "$SSH_FIX_DESC" caution; fi

if [[ "$(sshd_opt passwordauthentication)" == "no" ]]; then check pass ssh.password "Password login disabled"
else check fail ssh.password "Password login enabled" ssh-hardening "$SSH_FIX_DESC" caution; fi

if [[ "$(sshd_opt kbdinteractiveauthentication)" == "no" ]]; then check pass ssh.kbd "Keyboard-interactive login disabled"
else check warn ssh.kbd "Keyboard-interactive login enabled" ssh-hardening "$SSH_FIX_DESC" caution; fi

if [[ "$(sshd_opt x11forwarding)" == "no" ]]; then check pass ssh.x11 "X11 forwarding disabled"
else check warn ssh.x11 "X11 forwarding enabled" ssh-hardening "$SSH_FIX_DESC" caution; fi

detail "listening on port(s): $(current_ssh_ports | tr '\n' ' ')"

# --- Accounts ---------------------------------------------------------------
heading "Accounts"
uid0=$(awk -F: '$3 == 0 && $1 != "root" { printf "%s ", $1 }' /etc/passwd)
if [[ -z "$uid0" ]]; then check pass accounts.uid0 "Only root has UID 0"
else check fail accounts.uid0 "Other UID 0 accounts: ${uid0% }" "" \
  "Investigate first, this can mean a compromise. Then: sudo userdel <name>"; fi

empty=$(awk -F: '$2 == "" { printf "%s ", $1 }' /etc/shadow)
if [[ -z "$empty" ]]; then check pass accounts.empty-password "No accounts with empty passwords"
else check fail accounts.empty-password "Accounts with empty passwords: ${empty% }" \
  "lock-users ${empty% }" "Lock these accounts' passwords (SSH keys still work)" caution; fi

detail "users with a login shell: $(awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ { printf "%s ", $1 }' /etc/passwd)"
detail "sudo group: $(getent group sudo | cut -d: -f4)"

# --- Firewall / intrusion prevention ----------------------------------------
heading "Firewall"
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  check pass firewall.ufw "UFW active"
  while IFS= read -r rule; do detail "  $rule"; done < <(ufw status | sed -n '/^--/,$p' | tail -n +2 | grep .)
else
  check fail firewall.ufw "UFW not active" firewall \
    "Enable UFW: deny inbound except SSH (current port kept open), HTTP and HTTPS" caution
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
  banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ { gsub(/[[:space:]]/, "", $2); print $2 }')
  check pass firewall.fail2ban "fail2ban active (sshd currently banned: ${banned:-0})"
else
  check warn firewall.fail2ban "fail2ban not running" fail2ban "Install and start fail2ban for SSH"
fi

# --- Network exposure -------------------------------------------------------
heading "Network"
if ! command -v ss >/dev/null; then
  check warn network.ss "Can't inspect open ports: the 'ss' tool (iproute2) is missing" \
    install-iproute2 "Install iproute2 so the audit can check listening ports"
else
detail "listening ports (not localhost):"
# Skip the DHCP client (udp 68), which every cloud VM has.
while IFS= read -r line; do detail "  $line"; done < <(
  ss -tulnpH 2>/dev/null \
    | awk '$5 !~ /^(127\.|\[::1\]|::1)/ && !($1 == "udp" && $5 ~ /:68$/) { split($7, p, "\""); printf "%-4s %-28s %s\n", $1, $5, p[2] }' \
    | sort -u)

if ss -tulnH 2>/dev/null | awk '{print $5}' | grep -Eq '^(0\.0\.0\.0|\[::\]|\*):111$'; then
  check warn network.rpcbind "rpcbind listens on port 111 (only needed for NFS)" rpcbind "Stop and disable rpcbind"
else
  check pass network.rpcbind "rpcbind not exposed"
fi
fi

if command -v docker >/dev/null && systemctl is-active --quiet docker; then
  # Docker-published ports skip UFW. That's fine for ports UFW allows anyway
  # (e.g. 80/443 on a reverse proxy); flag only the others.
  ufw_allowed=" $(ufw status 2>/dev/null | awk '$2 ~ /^(ALLOW|LIMIT)$/ && $1 ~ /^[0-9]+(\/(tcp|udp))?$/ {printf "%s ", $1}') "
  expected=()
  flagged=0
  while IFS=$'\t' read -r cname ports; do
    # shellcheck disable=SC2013  # tokens like 443/udp never contain spaces
    for pp in $(grep -oE '(0\.0\.0\.0|\[::\]|::):[0-9-]+->[0-9-]+/(tcp|udp)' <<< "$ports" \
                | sed -E 's/^.*:([0-9-]+)->[0-9-]+\/(tcp|udp)$/\1\/\2/' | sort -u); do
      if [[ "$ufw_allowed" == *" $pp "* || "$ufw_allowed" == *" ${pp%/*} "* ]]; then
        expected+=("$pp")
      else
        flagged=1
        check warn "network.docker-port.$pp" "Container $cname publishes $pp to the internet, but UFW doesn't allow it (Docker bypasses UFW)" \
          "docker-allow $pp" "It's meant to be public: allow $pp in UFW so the firewall matches. (Not meant to be public? Publish it as 127.0.0.1:PORT instead.)" caution
      fi
    done
  done < <(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null)

  if (( ! flagged )); then
    if [[ ${#expected[@]} -gt 0 ]]; then
      check pass network.docker "Docker publishes only ports UFW also allows: $(printf '%s\n' "${expected[@]}" | sort -u | tr '\n' ' ')"
    else
      check pass network.docker "No Docker containers publish ports to the internet"
    fi
  fi
fi

if command -v nginx >/dev/null; then
  if nginx -T 2>/dev/null | grep -qE '^\s*server_tokens\s+off'; then check pass network.nginx-tokens "nginx hides its version"
  else check warn network.nginx-tokens "nginx shows its version in responses" nginx-tokens "Set server_tokens off and reload nginx"; fi
fi

# --- Tailscale --------------------------------------------------------------
if command -v tailscale >/dev/null; then
  heading "Tailscale"
  if tailscale_online; then
    ts_name=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//')
    check pass tailscale.online "Connected: $(tailscale ip -4 2>/dev/null) ${ts_name}"
  else
    check warn tailscale.online "Installed but not connected" tailscale-up \
      "Log in: prints a URL, open it on your laptop and approve this server"
  fi
fi

# --- EC2 --------------------------------------------------------------------
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://169.254.169.254/latest/meta-data/ 2>/dev/null || true)
if [[ "$code" == "401" ]]; then
  heading "EC2"; check pass ec2.imdsv2 "IMDSv2 enforced (metadata requires a token)"
elif [[ "$code" == "200" ]]; then
  heading "EC2"; check warn ec2.imdsv2 "IMDSv1 allowed" "" \
    "From your machine: aws ec2 modify-instance-metadata-options --instance-id <id> --http-tokens required"
fi

# --- Result -----------------------------------------------------------------
if (( JSON )); then
  printf '{"type":"summary","pass":%d,"warn":%d,"fail":%d}\n' "$PASS" "$WARNS" "$FAILS"
else
  echo
  printf '%sResult:%s %d pass, %d warn, %d fail\n' "$C_BOLD" "$C_RESET" "$PASS" "$WARNS" "$FAILS"
fi
(( FAILS == 0 ))
