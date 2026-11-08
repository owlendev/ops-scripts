#!/usr/bin/env bash
# Tailscale VPN: reach this server privately from your devices.
# Optional: Tailscale SSH, and closing public SSH so it's only reachable over Tailscale.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

if ! command -v tailscale >/dev/null; then
  ensure_packages ca-certificates curl
  curl -fsSL "https://pkgs.tailscale.com/stable/$OS_ID/$OS_CODENAME.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/$OS_ID/$OS_CODENAME.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt_get update
  apt_install tailscale
  ok "Tailscale installed"
else
  ok "Tailscale already installed ($(tailscale version | head -1))"
fi
systemctl enable --now tailscaled >/dev/null 2>&1

# Tailscale's recommended UFW rule: trust traffic arriving over the tailnet.
# 41641/udp lets devices connect directly instead of through a relay.
if ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow in on tailscale0 comment 'Tailscale' >/dev/null
  ufw allow 41641/udp comment 'Tailscale direct connections' >/dev/null
  info "UFW: allowed traffic on tailscale0 and 41641/udp"
fi

ssh_flag=false
is_true "$TAILSCALE_SSH" && ssh_flag=true
flags=(--ssh="$ssh_flag")
[[ -n "$TAILSCALE_HOSTNAME" ]] && flags+=(--hostname="$TAILSCALE_HOSTNAME")

if tailscale_online; then
  tailscale set "${flags[@]}"
  ok "Already connected; applied settings (Tailscale SSH: $ssh_flag)"
elif [[ -n "$TAILSCALE_AUTHKEY" ]]; then
  up=("${flags[@]}" --auth-key="$TAILSCALE_AUTHKEY" --timeout=90s)
  [[ -n "$TAILSCALE_TAGS" ]] && up+=(--advertise-tags="$TAILSCALE_TAGS")
  info "Connecting to your tailnet"
  tailscale up "${up[@]}" || die "tailscale up failed. Is the auth key valid and unused (or reusable)?"
  ok "Connected to your tailnet"
else
  warn "Not logged in to Tailscale yet. Run this and open the URL it prints:"
  warn "  sudo tailscale up$($ssh_flag && echo ' --ssh')${TAILSCALE_HOSTNAME:+ --hostname=$TAILSCALE_HOSTNAME}"
  exit 0
fi

name="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"
ok "Tailscale IP: $(tailscale ip -4)${name:+  name: $name}"
info "From any device on your tailnet:  ssh $ADMIN_USER@${name:-$(tailscale ip -4)}"

# Close public SSH now that Tailscale works. The firewall module does the actual
# rule changes, so re-running bootstrap keeps it consistent.
if is_true "$TAILSCALE_SSH_ONLY"; then
  bash "$OPS_ROOT/modules/30-firewall.sh"
fi
