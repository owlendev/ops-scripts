#!/usr/bin/env bash
# Docker Engine + compose plugin from Docker's official apt repository.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  # Remove distro packages that conflict with docker-ce.
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    pkg_installed "$p" && apt_get remove "$p"
  done

  apt_get update
  apt_install ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

  apt_get update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "Docker installed"
else
  ok "Docker already installed"
fi

# Rotate container logs; the default json-file driver grows without limit.
if [[ ! -f /etc/docker/daemon.json ]]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
  systemctl restart docker
  info "Wrote /etc/docker/daemon.json (log rotation)"
fi

systemctl enable --now docker containerd >/dev/null 2>&1

if is_true "$DOCKER_ADD_ADMIN_TO_GROUP" && user_exists "$ADMIN_USER"; then
  if ! id -nG "$ADMIN_USER" | grep -qw docker; then
    usermod -aG docker "$ADMIN_USER"
    info "Added $ADMIN_USER to the docker group (log out and back in to use it)"
  fi
fi

ok "$(docker --version), $(docker compose version)"
warn "Docker-published ports BYPASS UFW. Publish as 127.0.0.1:PORT:PORT and put nginx in front,"
warn "or rely on the EC2 security group to block them."
