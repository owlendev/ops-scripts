#!/usr/bin/env bash
# AdGuard Home DNS: ad blocking + local names (run on its own LXC).
# Installs the latest release (checksum verified), sets it up without the web wizard,
# and adds ADGUARD_REWRITES, e.g. "*.home.internal=192.168.1.50" (the apps VM).
# Its own box on purpose: if the apps VM is down, your whole network still has DNS.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config
ensure_packages curl jq ca-certificates

DIR=/opt/AdGuardHome
BIN="$DIR/AdGuardHome"
CREDS=/root/adguard-admin.txt

# --- Install -------------------------------------------------------------------
if [[ ! -x "$BIN" ]]; then
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=armv7 ;;
    *) die "No AdGuard Home build for CPU $(uname -m)" ;;
  esac
  rel="$(gh_latest_release AdguardTeam/AdGuardHome)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  gh_download_asset "$rel" "AdGuardHome_linux_${arch}.tar.gz" "$tmp/agh.tar.gz"
  tar -xzf "$tmp/agh.tar.gz" -C /opt
  "$BIN" -s install >/dev/null 2>&1 || die "AdGuard Home's service install failed"
  ok "AdGuard Home $(jq -r .tag_name <<< "$rel") installed in $DIR"
else
  ok "AdGuard Home already installed (it updates itself from its web UI)"
fi

# --- Free port 53: systemd-resolved's stub listener holds it on Ubuntu ------------
if command -v systemctl >/dev/null && systemctl is-active --quiet systemd-resolved && ss -lunpH 'sport = :53' | grep -q systemd-resolve; then
  write_if_changed /etc/systemd/resolved.conf.d/adguardhome.conf 0644 <<'EOF' || true
# Managed by ops-scripts (modules/87-adguard.sh): AdGuard Home serves port 53.
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved
  info "Turned off systemd-resolved's stub on port 53"
fi

# --- Firewall: DNS from the LAN (web UI: HTTP 80 from the firewall module) ---------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow 53/udp comment 'DNS' >/dev/null
  ufw allow 53/tcp comment 'DNS' >/dev/null
  info "UFW: allowed DNS (53/udp, 53/tcp)"
fi

# --- First-time setup (what the :3000 web wizard would do) ----------------------
if [[ ! -s "$DIR/AdGuardHome.yaml" ]]; then
  if [[ -z "$ADGUARD_PASSWORD" ]]; then
    ADGUARD_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=')"
    umask 077
    printf 'AdGuard Home web UI: http://%s/\nuser: %s\npassword: %s\n' \
      "$(hostname -I | awk '{print $1}')" "$ADGUARD_USER" "$ADGUARD_PASSWORD" > "$CREDS"
    info "Generated the admin password: saved to $CREDS"
  fi
  (( ${#ADGUARD_PASSWORD} >= 8 )) || die "ADGUARD_PASSWORD must be at least 8 characters"
  for _ in $(seq 1 20); do curl -fs -o /dev/null http://127.0.0.1:3000/ && break; sleep 1; done
  body="$(jq -n --arg u "$ADGUARD_USER" --arg p "$ADGUARD_PASSWORD" \
    '{web: {ip: "0.0.0.0", port: 80}, dns: {ip: "0.0.0.0", port: 53}, username: $u, password: $p}')"
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$body" \
    http://127.0.0.1:3000/control/install/configure >/dev/null ||
    die "AdGuard's first-time setup failed. Finish it by hand at http://$(hostname -I | awk '{print $1}'):3000"
  ok "AdGuard Home set up: web UI on port 80, DNS on port 53"
  sleep 2
fi

# --- API calls need the login -------------------------------------------------
if [[ -z "$ADGUARD_PASSWORD" && -r "$CREDS" ]]; then
  ADGUARD_PASSWORD="$(awk '/^password:/ { print $2 }' "$CREDS")"
fi
if [[ -z "$ADGUARD_PASSWORD" ]]; then
  [[ -z "$ADGUARD_REWRITES$ADGUARD_UPSTREAMS" ]] ||
    warn "Set ADGUARD_PASSWORD to let this module manage rewrites/upstreams; add them in the web UI meanwhile."
  exit 0
fi
api() { # method path [json]
  curl -fsS -u "$ADGUARD_USER:$ADGUARD_PASSWORD" -X "$1" -H 'Content-Type: application/json' \
    ${3:+-d "$3"} "http://127.0.0.1/control/$2"
}
for _ in $(seq 1 20); do api GET status >/dev/null 2>&1 && break; sleep 1; done
api GET status >/dev/null || die "Can't log in to AdGuard's API (wrong ADGUARD_USER/ADGUARD_PASSWORD?)"

# --- Local names --------------------------------------------------------------------
have="$(api GET rewrite/list)"
for pair in $ADGUARD_REWRITES; do
  [[ "$pair" == *=* ]] || die "ADGUARD_REWRITES entry '$pair' must look like name=ip"
  d="${pair%%=*}" a="${pair#*=}"
  if jq -e --arg d "$d" --arg a "$a" 'any(.[]; .domain == $d and .answer == $a)' <<< "$have" >/dev/null; then
    ok "Rewrite $d -> $a"
    continue
  fi
  # Same name pointing elsewhere: replace it.
  jq -c --arg d "$d" '.[] | select(.domain == $d)' <<< "$have" | while read -r old; do
    api POST rewrite/delete "$old" >/dev/null
  done
  api POST rewrite/add "$(jq -nc --arg d "$d" --arg a "$a" '{domain: $d, answer: $a}')" >/dev/null
  ok "Rewrite $d -> $a (added)"
done

# --- Upstreams ------------------------------------------------------------------
if [[ -n "$ADGUARD_UPSTREAMS" ]]; then
  # shellcheck disable=SC2086
  api POST dns_config "$(jq -nc --args '{upstream_dns: $ARGS.positional}' $ADGUARD_UPSTREAMS)" >/dev/null
  ok "Upstream DNS: $ADGUARD_UPSTREAMS"
fi

ip="$(hostname -I | awk '{print $1}')"
ok "DNS server: $ip   web UI: http://$ip/"
info "Router: set the DHCP DNS server to $ip, so every device uses it."
first="${ADGUARD_REWRITES%% *}"; first="${first%%=*}"
[[ -n "$first" ]] && info "Test from any machine:  dig +short ${first/\*/test} @$ip"
exit 0
