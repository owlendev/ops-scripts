#!/usr/bin/env bash
# Update all packages, set timezone and (optionally) hostname.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

info "Updating package lists"
apt_get update

info "Upgrading installed packages (this can take a few minutes)"
apt_get dist-upgrade
apt_get autoremove --purge
apt_get clean
ok "System packages are up to date"

if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "$TIMEZONE" ]]; then
  timedatectl set-timezone "$TIMEZONE"
  ok "Timezone set to $TIMEZONE"
else
  ok "Timezone already $TIMEZONE"
fi

# Make sure the clock is synced (TLS and logs depend on it).
timedatectl set-ntp true 2>/dev/null || true

if [[ -n "$HOSTNAME_FQDN" && "$(hostname -f 2>/dev/null)" != "$HOSTNAME_FQDN" ]]; then
  hostnamectl set-hostname "$HOSTNAME_FQDN"
  short="${HOSTNAME_FQDN%%.*}"
  if ! grep -qE "^127\.0\.1\.1\s+$HOSTNAME_FQDN" /etc/hosts; then
    sed -i '/^127\.0\.1\.1\s/d' /etc/hosts
    echo "127.0.1.1 $HOSTNAME_FQDN $short" >> /etc/hosts
  fi
  # Stop cloud-init from resetting the hostname on reboot.
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-ops-hostname.cfg
  fi
  ok "Hostname set to $HOSTNAME_FQDN"
fi

if [[ -f /var/run/reboot-required ]]; then
  warn "Reboot required after updates ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null || true))"
fi
