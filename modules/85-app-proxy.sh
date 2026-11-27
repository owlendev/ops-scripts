#!/usr/bin/env bash
# Caddy in front of all Docker apps, HTTPS by name + ops-app command.
# Every app gets https://<name>.$APPS_DOMAIN; only Caddy publishes ports (80/443), so
# apps never clash. Apps join the shared 'proxy' Docker network. Needs the docker module.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

command -v docker >/dev/null && docker info >/dev/null 2>&1 ||
  die "Docker isn't running. Enable the docker module too (ENABLE_DOCKER=yes)."

SRC="$OPS_ROOT/apps"
PROXY="$APPS_DIR/_proxy"
TEMPLATES=/usr/local/share/ops-app/templates

case "$PROXY_TLS" in
  internal) ;;
  cloudflare)
    [[ -n "$PROXY_CF_API_TOKEN" ]] || die "PROXY_TLS=cloudflare needs PROXY_CF_API_TOKEN (Cloudflare → My Profile → API Tokens → 'Edit zone DNS')."
    [[ "$APPS_DOMAIN" != *.internal && "$APPS_DOMAIN" != internal ]] ||
      die "PROXY_TLS=cloudflare needs a domain you own on Cloudflare, not $APPS_DOMAIN."
    ;;
  *) die "PROXY_TLS must be internal or cloudflare, not '$PROXY_TLS'." ;;
esac
[[ "$APPS_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "APPS_DOMAIN '$APPS_DOMAIN' isn't a valid domain."

# --- Ports 80/443 must be free for Caddy (nginx on the same VM would hold them) ---
for p in 80 443; do
  holder="$(ss -ltnpH "sport = :$p" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | cut -d'"' -f2 || true)"
  if [[ -n "$holder" && "$holder" != docker-proxy ]]; then
    die "Port $p is used by '$holder'. Caddy needs 80 and 443: stop it (nginx? sudo systemctl disable --now nginx) or don't enable both."
  fi
done

# --- The shared network every app joins ------------------------------------
if docker network inspect proxy >/dev/null 2>&1; then
  have="$(docker network inspect proxy -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
  [[ "$have" == "$PROXY_SUBNET" ]] || warn "Network 'proxy' uses $have, not PROXY_SUBNET=$PROXY_SUBNET; keeping it (Nextcloud's TRUSTED_PROXIES must match $have)."
  PROXY_SUBNET="$have"
  ok "Docker network 'proxy' exists ($have)"
else
  docker network create --driver bridge --subnet "$PROXY_SUBNET" proxy >/dev/null ||
    die "Couldn't create the 'proxy' network on $PROXY_SUBNET (clashes with your LAN? set PROXY_SUBNET)."
  ok "Created Docker network 'proxy' ($PROXY_SUBNET)"
fi

# --- Folders: $APPS_DIR/<app>/ and $APPS_DIR/_proxy/ --------------------------
# Group docker can manage apps without sudo (docker group = root-equivalent anyway).
install -d -m 2775 -o root -g docker "$APPS_DIR" "$PROXY" "$PROXY/conf" "$PROXY/conf/sites" "$PROXY/public"
changed=0
write_if_changed "$PROXY/compose.yml" 0644 < "$SRC/proxy/compose.yml" && changed=1 || true

# --- Caddy image -------------------------------------------------------------
caddy_version="$(grep -oE 'caddy:[0-9.]+' "$SRC/proxy/compose.yml" | head -1 | cut -d: -f2)"
if [[ "$PROXY_TLS" == cloudflare ]]; then
  image="ops-caddy-cloudflare:$caddy_version"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    info "Building Caddy $caddy_version with the Cloudflare DNS plugin (a minute or two)"
    docker build -q -t "$image" --build-arg CADDY_VERSION="$caddy_version" \
      -f "$SRC/proxy/Dockerfile.cloudflare" "$SRC/proxy" >/dev/null || die "Building the Caddy image failed"
  fi
else
  image="caddy:$caddy_version"
fi

# --- .env (secrets: root only) ----------------------------------------------
write_if_changed "$PROXY/.env" 0600 <<EOF && changed=1 || true
# Managed by ops-scripts (modules/85-app-proxy.sh): change config/default.env or your
# client config, then re-run the module. Holds secrets.
CADDY_IMAGE=$image
APPS_DOMAIN=$APPS_DOMAIN
PROXY_ALLOW_FROM=$PROXY_ALLOW_FROM
CF_API_TOKEN=$PROXY_CF_API_TOKEN
PROXY_ACME_EMAIL=$PROXY_ACME_EMAIL
EOF

# --- Caddyfile -----------------------------------------------------------------
if [[ "$PROXY_TLS" == cloudflare ]]; then
  global=$'\temail {$PROXY_ACME_EMAIL}\n\tacme_dns cloudflare {env.CF_API_TOKEN}'
  ca_site=""
else
  global=$'\tlocal_certs'
  ca_site=$'# Root certificate download page, for setting up devices: http://ca.{$APPS_DOMAIN}\nhttp://ca.{$APPS_DOMAIN} {\n\timport secure\n\troot * /srv/public\n\tfile_server\n}\n'
fi
write_if_changed "$PROXY/conf/Caddyfile" 0644 <<EOF && changed=1 || true
# Managed by ops-scripts (modules/85-app-proxy.sh). Don't edit: add apps with ops-app,
# which writes one file per app into sites/.
{
$global
}

# Every app imports this: LAN + Tailscale only, basic security headers.
(secure) {
	@outsiders not remote_ip {\$PROXY_ALLOW_FROM}
	respond @outsiders "Forbidden" 403
	header {
		-Server
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
	}
	encode zstd gzip
}

# Any name without an app.
*.{\$APPS_DOMAIN} {
	import secure
	respond "No app is set up at {host}. See: ops-app list" 404
}

$ca_site
import /etc/caddy/sites/*.caddy
EOF

# --- ops-app -------------------------------------------------------------------
install -m 0755 "$SRC/ops-app" /usr/local/bin/ops-app
rm -rf "$TEMPLATES"; mkdir -p "$TEMPLATES"; cp -r "$SRC/templates/." "$TEMPLATES/"
write_if_changed /etc/ops-app.env 0644 <<EOF || true
# Managed by ops-scripts (modules/85-app-proxy.sh)
APPS_DIR=$APPS_DIR
APPS_DOMAIN=$APPS_DOMAIN
PROXY_SUBNET=$PROXY_SUBNET
TEMPLATES_DIR=$TEMPLATES
EOF
ok "Installed ops-app (try: ops-app help)"

# --- Start / reload Caddy --------------------------------------------------------
out="$(cd "$PROXY" && docker compose up -d --quiet-pull 2>&1)" ||
  { printf '%s\n' "$out" | tail -5 >&2; die "Caddy didn't start: cd $PROXY && docker compose logs"; }
for _ in $(seq 1 15); do
  [[ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" == true ]] && break
  sleep 1
done
if ! docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -5 >&2 || true
  die "Caddy's config is invalid (see above)."
fi
(( changed )) && docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
ok "Caddy running: https://<app>.$APPS_DOMAIN, from ${PROXY_ALLOW_FROM}"

# --- Export the root certificate so devices can trust it --------------------------
if [[ "$PROXY_TLS" == internal ]]; then
  crt=""
  for _ in $(seq 1 20); do
    crt="$(docker exec caddy cat /data/caddy/pki/authorities/local/root.crt 2>/dev/null || true)"
    [[ -n "$crt" ]] && break
    sleep 1
  done
  if [[ -n "$crt" ]]; then
    printf '%s\n' "$crt" | write_if_changed "$PROXY/public/root.crt" 0644 || true
    fp="$(openssl x509 -in "$PROXY/public/root.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
    sed -e "s|__DOMAIN__|$APPS_DOMAIN|g" -e "s|__FP__|$fp|g" "$SRC/proxy/index.html" |
      write_if_changed "$PROXY/public/index.html" 0644 || true
    ok "Root certificate: http://ca.$APPS_DOMAIN (install once per device; details: ops-app ca)"
  else
    warn "Caddy hasn't made its root certificate yet. Re-run this module in a minute."
  fi
else
  rm -f "$PROXY/public/root.crt" "$PROXY/public/index.html"
fi

ip="$(hostname -I | awk '{print $1}')"
info "DNS: in AdGuard add the rewrite  *.$APPS_DOMAIN -> $ip  (or ADGUARD_REWRITES on the DNS box)"
info "Next: ops-app new <name> --image IMAGE --port N, or ops-app adopt kontor --port 8080"
