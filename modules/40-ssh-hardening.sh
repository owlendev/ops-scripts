#!/usr/bin/env bash
# Harden sshd: key-only login, no root login, shorter timeouts.
# Refuses to run if the admin user has no SSH key (prevents lockout).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

DROPIN=/etc/ssh/sshd_config.d/00-ops-hardening.conf

# --- Lockout protection -----------------------------------------------------
user_exists "$ADMIN_USER" || die "ADMIN_USER '$ADMIN_USER' does not exist. Set ADMIN_USER in your config."
keys="$(user_home "$ADMIN_USER")/.ssh/authorized_keys"
if [[ ! -s "$keys" ]] || ! grep -qE '^(ssh-|ecdsa-|sk-)' "$keys"; then
  die "No SSH public key in $keys. Refusing to disable password login (you would be locked out)."
fi
ok "$ADMIN_USER has SSH key(s) in $keys"

# sshd uses the FIRST value it reads for each option. Ubuntu's sshd_config
# includes sshd_config.d/*.conf at the top, and cloud-init writes
# 50-cloud-init.conf (sometimes with PasswordAuthentication yes), so our file
# is named 00-* to win.
if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  info "Added sshd_config.d Include to /etc/ssh/sshd_config"
fi

tcp_forwarding=no
is_true "$SSH_ALLOW_TCP_FORWARDING" && tcp_forwarding=yes

old_ports="$(current_ssh_ports | tr '\n' ' ')"

changed=0
write_if_changed "$DROPIN" 0644 <<EOF && changed=1
# Managed by ops-scripts (modules/40-ssh-hardening.sh). Local edits will be overwritten.
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding $tcp_forwarding
PermitUserEnvironment no
$( [[ -n "$SSH_ALLOW_USERS" ]] && echo "AllowUsers $SSH_ALLOW_USERS" )
EOF

if (( changed == 0 )); then
  ok "sshd hardening already applied"
  exit 0
fi

mkdir -p /run/sshd
if ! sshd -t; then
  rm -f "$DROPIN"
  die "sshd config test failed; removed $DROPIN and left sshd untouched."
fi

# If the port changes and UFW is on, open the new port before restarting.
if [[ " $old_ports " != *" $SSH_PORT "* ]] && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw limit "$SSH_PORT/tcp" comment 'SSH' >/dev/null
  info "Opened new SSH port $SSH_PORT in UFW"
fi

# Ubuntu 22.10+ uses socket activation: the port comes from ssh.socket.
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
  systemctl daemon-reload
  systemctl restart ssh.socket
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd
ok "sshd hardened and restarted (existing sessions stay connected)"

if [[ " $old_ports " != *" $SSH_PORT "* ]]; then
  warn "SSH port changed from ${old_ports% } to $SSH_PORT."
  warn "Open $SSH_PORT in the EC2 security group and test a NEW session before closing this one."
  warn "Then remove the old rule: sudo ufw delete limit ${old_ports%% *}/tcp"
fi
