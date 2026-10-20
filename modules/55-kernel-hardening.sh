#!/usr/bin/env bash
# Network/kernel sysctl hardening. Leaves ip_forward alone (Docker needs it).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

CONF=/etc/sysctl.d/99-ops-hardening.conf

if write_if_changed "$CONF" 0644 <<'EOF'
# Managed by ops-scripts (modules/55-kernel-hardening.sh)

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Reverse-path filtering (2 = loose; safe with multiple ENIs on EC2)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Ignore ICMP redirects and source-routed packets; we are not a router
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Log spoofed/impossible packets; ignore broadcast pings and bogus ICMP errors
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Hide kernel pointers and dmesg from non-root users
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# Protect against hard/symlink attacks in world-writable dirs
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
then
  info "Wrote $CONF"
fi

sysctl -q -p "$CONF"
ok "Kernel hardening applied"
