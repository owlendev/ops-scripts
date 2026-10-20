#!/usr/bin/env bash
# nginx web server + certbot. Requests a Let's Encrypt certificate when
# CERTBOT_DOMAINS and CERTBOT_EMAIL are set (DNS must already point here).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

pkg_installed nginx || { apt_get update; apt_install nginx; }

# Don't advertise the nginx version.
write_if_changed /etc/nginx/conf.d/00-ops-security.conf 0644 <<'EOF' || true
# Managed by ops-scripts (modules/80-nginx.sh)
server_tokens off;
EOF

# Headers to include from your site's server {} block:
#   include snippets/security-headers.conf;
write_if_changed /etc/nginx/snippets/security-headers.conf 0644 <<'EOF' || true
# Managed by ops-scripts (modules/80-nginx.sh)
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
# Enable only once HTTPS works for every subdomain:
# add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF

nginx -t 2>&1 | sed 's/^/    /'
systemctl enable --now nginx >/dev/null 2>&1
systemctl reload nginx
ok "nginx running"

is_true "$INSTALL_CERTBOT" || exit 0

if ! command -v certbot >/dev/null; then
  apt_get update
  apt_install certbot python3-certbot-nginx
  ok "certbot installed (auto-renewal via certbot.timer)"
fi

if [[ -z "$CERTBOT_DOMAINS" ]]; then
  info "No CERTBOT_DOMAINS set. Later run:  sudo certbot --nginx -d example.com -d www.example.com"
  exit 0
fi
[[ -n "$CERTBOT_EMAIL" ]] || die "CERTBOT_DOMAINS is set but CERTBOT_EMAIL is empty."

domain_args=()
for d in $CERTBOT_DOMAINS; do domain_args+=(-d "$d"); done
first="${CERTBOT_DOMAINS%% *}"

if [[ -d "/etc/letsencrypt/live/$first" ]]; then
  ok "Certificate for $first already exists"
  exit 0
fi

info "Requesting certificate for: $CERTBOT_DOMAINS"
if certbot --nginx --non-interactive --agree-tos --redirect -m "$CERTBOT_EMAIL" "${domain_args[@]}"; then
  ok "HTTPS enabled for $CERTBOT_DOMAINS"
else
  # Most common cause: DNS not pointing here yet. Don't fail the bootstrap.
  warn "certbot failed. Check DNS A records point to this server and port 80 is open, then run:"
  warn "  sudo certbot --nginx ${domain_args[*]} -m $CERTBOT_EMAIL --redirect"
fi
