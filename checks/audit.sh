#!/usr/bin/env bash
# Read-only security/health report. Changes nothing.
# Exit code: 0 = no failures, 1 = at least one FAIL.
set -uo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

PASS=0; WARNS=0; FAILS=0
pass()  { printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$*"; PASS=$((PASS + 1)); }
check_warn() { printf '  %sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNS=$((WARNS + 1)); }
fail()  { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; FAILS=$((FAILS + 1)); }
note()  { printf '  %s\n' "$*"; }

section "Audit: $(hostname) — $OS_ID $OS_VERSION — kernel $(uname -r)"

# --- System -----------------------------------------------------------------
echo "System"
note "uptime: $(uptime -p)"
if [[ -f /var/run/reboot-required ]]; then check_warn "Reboot required"; else pass "No reboot required"; fi

upgradable=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst' || true)
security=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst' | grep -ci security || true)
if (( security > 0 )); then fail "$security pending security update(s) ($upgradable total)"
elif (( upgradable > 0 )); then check_warn "$upgradable pending update(s), none security"
else pass "All packages up to date"; fi

if [[ "$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null)" == *'"1"'* ]]; then
  pass "Unattended upgrades enabled"
else
  check_warn "Unattended upgrades not enabled"
fi

if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
  pass "Clock synchronized (timezone $(timedatectl show -p Timezone --value))"
else
  check_warn "Clock not synchronized"
fi

root_use=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if (( root_use >= 90 )); then fail "Root disk ${root_use}% full"
elif (( root_use >= 80 )); then check_warn "Root disk ${root_use}% full"
else pass "Root disk ${root_use}% used"; fi

mem=$(free -h | awk '/^Mem:/ {print $3"/"$2}')
swap=$(free -h | awk '/^Swap:/ {print $2}')
note "memory used: $mem, swap: $swap"

# --- SSH --------------------------------------------------------------------
echo; echo "SSH"
mkdir -p /run/sshd
sshd_conf="$(sshd -T 2>/dev/null)"
sshd_opt() { awk -v k="$1" '$1 == k { print $2; exit }' <<< "$sshd_conf"; }

[[ "$(sshd_opt permitrootlogin)" == "no" ]] && pass "Root login disabled" || fail "Root login allowed (permitrootlogin $(sshd_opt permitrootlogin))"
[[ "$(sshd_opt passwordauthentication)" == "no" ]] && pass "Password login disabled" || fail "Password login enabled"
[[ "$(sshd_opt kbdinteractiveauthentication)" == "no" ]] && pass "Keyboard-interactive login disabled" || check_warn "Keyboard-interactive login enabled"
[[ "$(sshd_opt x11forwarding)" == "no" ]] && pass "X11 forwarding disabled" || check_warn "X11 forwarding enabled"
note "listening on port(s): $(current_ssh_ports | tr '\n' ' ')"

# --- Accounts ---------------------------------------------------------------
echo; echo "Accounts"
uid0=$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd)
[[ -z "$uid0" ]] && pass "Only root has UID 0" || fail "Other UID 0 accounts: $uid0"
empty=$(awk -F: '$2 == "" { print $1 }' /etc/shadow)
[[ -z "$empty" ]] && pass "No accounts with empty passwords" || fail "Accounts with empty passwords: $empty"
note "users with a login shell: $(awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ { printf "%s ", $1 }' /etc/passwd)"
note "sudo group: $(getent group sudo | cut -d: -f4)"

# --- Firewall / intrusion prevention ----------------------------------------
echo; echo "Firewall"
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  pass "UFW active"
  ufw status | sed -n '/^--/,$p' | tail -n +2 | grep . | sed 's/^/      /'
else
  fail "UFW not active"
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
  banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ { gsub(/[[:space:]]/, "", $2); print $2 }')
  pass "fail2ban active (sshd currently banned: ${banned:-0})"
else
  check_warn "fail2ban not running"
fi

# --- Network exposure -------------------------------------------------------
echo; echo "Listening ports (not localhost)"
ss -tulnpH 2>/dev/null \
  | awk '$5 !~ /^(127\.|\[::1\]|::1)/ { split($7, p, "\""); printf "      %-4s %-28s %s\n", $1, $5, p[2] }' \
  | sort -u

if command -v docker >/dev/null && systemctl is-active --quiet docker; then
  exposed=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0:|:::' || true)
  if [[ -n "$exposed" ]]; then
    check_warn "Docker containers publishing on all interfaces (bypasses UFW):"
    sed 's/^/      /' <<< "$exposed"
  else
    pass "No Docker containers publishing on all interfaces"
  fi
fi

if command -v nginx >/dev/null; then
  nginx -T 2>/dev/null | grep -qE '^\s*server_tokens\s+off' && pass "nginx hides its version" || check_warn "nginx server_tokens not off"
fi

# --- EC2 --------------------------------------------------------------------
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://169.254.169.254/latest/meta-data/ 2>/dev/null || true)
if [[ "$code" == "401" ]]; then
  echo; echo "EC2"; pass "IMDSv2 enforced (metadata requires a token)"
elif [[ "$code" == "200" ]]; then
  echo; echo "EC2"; check_warn "IMDSv1 allowed. Enforce v2: aws ec2 modify-instance-metadata-options --instance-id <id> --http-tokens required"
fi

# --- Result -----------------------------------------------------------------
echo
printf '%sResult:%s %d pass, %d warn, %d fail\n' "$C_BOLD" "$C_RESET" "$PASS" "$WARNS" "$FAILS"
(( FAILS == 0 ))
