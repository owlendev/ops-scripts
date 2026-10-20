#!/usr/bin/env bash
# Install everyday admin and network troubleshooting tools.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

# shellcheck disable=SC2206
packages=($BASE_PACKAGES $EXTRA_PACKAGES)

missing=()
for p in "${packages[@]}"; do
  pkg_installed "$p" || missing+=("$p")
done

if [[ ${#missing[@]} -eq 0 ]]; then
  ok "All ${#packages[@]} base packages already installed"
  exit 0
fi

info "Installing: ${missing[*]}"
apt_get update
apt_install "${missing[@]}"
ok "Installed ${#missing[@]} package(s)"
