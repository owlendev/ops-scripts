#!/usr/bin/env bash
# fail2ban: temporarily ban IPs that brute-force SSH.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

if ! pkg_installed fail2ban || ! pkg_installed python3-systemd; then
  apt_get update
  apt_install fail2ban python3-systemd
fi

# Read sshd failures from the systemd journal (newer Ubuntu/Debian may not
# write /var/log/auth.log at all).
if write_if_changed /etc/fail2ban/jail.d/ops-sshd.local 0644 <<EOF
# Managed by ops-scripts (modules/45-fail2ban.sh)
[DEFAULT]
bantime  = $FAIL2BAN_BANTIME
findtime = $FAIL2BAN_FINDTIME
maxretry = $FAIL2BAN_MAXRETRY
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = $SSH_PORT
EOF
then
  info "Wrote /etc/fail2ban/jail.d/ops-sshd.local"
fi

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2
if fail2ban-client status sshd >/dev/null 2>&1; then
  ok "fail2ban running with sshd jail"
else
  die "fail2ban sshd jail is not running. Check: journalctl -u fail2ban"
fi
