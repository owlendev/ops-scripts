#!/usr/bin/env bash
# Fixes for problems found by checks/audit.sh. Each fix is safe to re-run.
#
#   sudo checks/fix.sh --list
#   sudo checks/fix.sh <fix> [args]      e.g. sudo checks/fix.sh rpcbind
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 <fix> [args]

Fixes:
  updates               Install all pending package updates
  reboot                Reboot now
  auto-updates          Enable unattended security updates
  ntp                   Turn on network time sync
  disk                  Free disk space (apt cache, old packages, journal > 200M)
  ssh-hardening         Keys-only SSH, no root login (keeps the current SSH port)
  lock-users USER...    Lock the password of these accounts
  firewall              Enable UFW (keeps the current SSH port open)
  fail2ban              Install and start fail2ban for SSH
  install-iproute2      Install iproute2 (provides ss, used to inspect ports)
  rpcbind               Stop and disable rpcbind (port 111)
  docker-allow P/PROTO  Allow a Docker-published port in UFW, e.g. 443/udp
  nginx-tokens          Hide the nginx version
  tailscale-up          Log in to Tailscale (prints a login URL)
  tool NAME...          Install these CLI/dev tools again and check that they work,
                        e.g. tool lazygit herdr
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 1; }
case "$1" in -h|--help|--list) usage; exit 0 ;; esac

require_root
require_supported_os

# Fixes that reuse a module must not move SSH to a different port: start from the
# port sshd uses now. A config file passed via OPS_CONFIG still wins.
cur_port="$(current_ssh_ports 2>/dev/null | head -1 || true)"
[[ -n "$cur_port" ]] && export SSH_PORT="$cur_port"
load_config

MOD="$OPS_ROOT/modules"
fix="$1"; shift

case "$fix" in
  updates)
    apt_get update
    if ! apt_get dist-upgrade; then
      # Usually stale package lists or a mirror mid-sync (404s). Retry once from scratch.
      warn "Upgrade failed; refreshing package lists and retrying once"
      apt_get clean
      rm -rf /var/lib/apt/lists/*
      apt_get update
      apt_get dist-upgrade --fix-missing
    fi
    apt_get autoremove --purge
    ok "Packages updated"
    if [[ -f /var/run/reboot-required ]]; then warn "A reboot is required to finish (fix: reboot)"; fi
    ;;
  reboot)
    warn "Rebooting now. Reconnect in about a minute."
    systemctl reboot
    ;;
  auto-updates)  bash "$MOD/50-auto-updates.sh" ;;
  ntp)
    timedatectl set-ntp true
    systemctl restart systemd-timesyncd 2>/dev/null || systemctl restart chrony 2>/dev/null || true
    sleep 3
    ok "NTP enabled (synchronized: $(timedatectl show -p NTPSynchronized --value))"
    ;;
  disk)
    before=$(df --output=avail -h / | tail -1 | tr -d ' ')
    apt_get clean
    apt_get autoremove --purge
    journalctl --vacuum-size=200M 2>&1 | tail -1
    ok "Free space on /: $before -> $(df --output=avail -h / | tail -1 | tr -d ' ')"
    if command -v docker >/dev/null; then info "Docker images can also use a lot of space: 'docker system df' (clean up with care)"; fi
    ;;
  ssh-hardening) bash "$MOD/40-ssh-hardening.sh" ;;
  lock-users)
    [[ $# -gt 0 ]] || die "lock-users needs at least one user"
    for u in "$@"; do
      [[ "$u" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] && user_exists "$u" || die "Not a valid user: $u"
      passwd -l "$u" >/dev/null
      ok "Locked password for $u"
    done
    ;;
  firewall)      bash "$MOD/30-firewall.sh" ;;
  fail2ban)      bash "$MOD/45-fail2ban.sh" ;;
  install-iproute2) ensure_packages iproute2; ok "iproute2 installed (ss is available)" ;;
  rpcbind)
    systemctl disable --now rpcbind.socket rpcbind.service 2>/dev/null || true
    if ss -tulnH | awk '{print $5}' | grep -Eq ':111$'; then
      die "Something still listens on port 111: $(ss -tulnpH | grep ':111 ' | head -1)"
    fi
    ok "rpcbind stopped and disabled"
    ;;
  docker-allow)
    [[ "${1:-}" =~ ^[0-9]+(-[0-9]+)?/(tcp|udp)$ ]] || die "Expected PORT/PROTO, e.g. 443/udp"
    ufw allow "${1/-/:}" comment 'Docker-published' >/dev/null
    ok "UFW now allows $1"
    ;;
  nginx-tokens)
    printf '# Managed by ops-scripts\nserver_tokens off;\n' > /etc/nginx/conf.d/00-ops-security.conf
    nginx -t
    systemctl reload nginx
    ok "nginx no longer shows its version"
    ;;
  tailscale-up)
    info "Open the URL below on your laptop and approve this server. Waiting..."
    tailscale up
    ok "Tailscale connected: $(tailscale ip -4)"
    ;;
  tool)
    [[ $# -gt 0 ]] || die "tool needs at least one tool name, e.g. tool lazygit"
    dev=(); cli=(); user=""
    for t in "$@"; do
      [[ "$t" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || die "Not a valid tool name: $t"
      line="$(awk -F'\t' -v n="$t" '$1 == n' "$TOOLS_STATE" 2>/dev/null | head -1)"
      kind="$(cut -f2 <<< "$line")"
      [[ -n "$line" ]] && user="$(cut -f4 <<< "$line")"
      case "$kind:$t" in
        dev:*|:git|:lazygit|:lazydocker|:neovim|:lazyvim|:herdr) dev+=("$t") ;;
        *) cli+=("$t") ;;
      esac
    done
    # Dev tools go to the same user as before (a config via OPS_CONFIG still wins).
    [[ -n "$user" && "$user" != root && -z "${OPS_CONFIG:-}" ]] && export ADMIN_USER="$user"
    rc=0
    if [[ ${#cli[@]} -gt 0 ]]; then CLI_TOOLS="${cli[*]}" bash "$MOD/22-cli-tools.sh" || rc=$?; fi
    if [[ ${#dev[@]} -gt 0 ]]; then DEV_TOOLS="${dev[*]}" bash "$MOD/60-dev-tools.sh" || rc=$?; fi
    exit "$rc"
    ;;
  *)
    usage >&2
    die "Unknown fix: $fix"
    ;;
esac
