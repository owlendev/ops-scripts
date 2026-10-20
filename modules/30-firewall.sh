#!/usr/bin/env bash
# Host firewall with UFW: deny all inbound except SSH (+ HTTP/HTTPS by default).
# On EC2 the security group is the first firewall; this is the second layer.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

pkg_installed ufw || { apt_get update; apt_install ufw; }

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Allow the configured SSH port AND whatever sshd listens on right now, so
# enabling the firewall (or changing SSH_PORT later) can never lock us out.
ssh_ports="$(printf '%s\n%s\n' "$SSH_PORT" "$(current_ssh_ports)" | grep -E '^[0-9]+$' | sort -u)"
for port in $ssh_ports; do
  if [[ -n "$SSH_ALLOW_FROM" ]]; then
    ufw limit proto tcp from "$SSH_ALLOW_FROM" to any port "$port" comment 'SSH' >/dev/null
    info "SSH port $port allowed from $SSH_ALLOW_FROM (rate limited)"
  else
    ufw limit "$port/tcp" comment 'SSH' >/dev/null
    info "SSH port $port allowed from anywhere (rate limited)"
  fi
done

if is_true "$FIREWALL_ALLOW_HTTP"; then
  ufw allow 80/tcp comment 'HTTP' >/dev/null && info "HTTP 80/tcp allowed"
fi
if is_true "$FIREWALL_ALLOW_HTTPS"; then
  ufw allow 443/tcp comment 'HTTPS' >/dev/null && info "HTTPS 443/tcp allowed"
fi
for rule in $FIREWALL_EXTRA_PORTS; do
  ufw allow "$rule" >/dev/null && info "$rule allowed"
done

ufw --force enable >/dev/null
ok "UFW active"
ufw status verbose | sed 's/^/    /'
