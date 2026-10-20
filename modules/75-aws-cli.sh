#!/usr/bin/env bash
# AWS CLI v2 (official installer). On EC2, prefer an IAM instance role over
# putting access keys on the server.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

if command -v aws >/dev/null && aws --version 2>&1 | grep -q 'aws-cli/2'; then
  ok "AWS CLI already installed: $(aws --version 2>&1)"
  exit 0
fi

case "$(uname -m)" in
  x86_64)  arch=x86_64 ;;
  aarch64) arch=aarch64 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

pkg_installed unzip || { apt_get update; apt_install unzip; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
info "Downloading AWS CLI v2 ($arch)"
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp/awscliv2.zip"
unzip -q "$tmp/awscliv2.zip" -d "$tmp"
"$tmp/aws/install" --update
ok "$(aws --version 2>&1)"
