#!/usr/bin/env bash
# Install security updates automatically every day.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

pkg_installed unattended-upgrades || { apt_get update; apt_install unattended-upgrades; }

write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

reboot=false
is_true "$AUTO_UPDATES_REBOOT" && reboot=true

write_if_changed /etc/apt/apt.conf.d/52ops-unattended-upgrades 0644 <<EOF || true
// Managed by ops-scripts (modules/50-auto-updates.sh)
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$reboot";
Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_UPDATES_REBOOT_TIME";
EOF

systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "Unattended security updates enabled (auto reboot: $reboot)"
