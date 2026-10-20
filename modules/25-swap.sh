#!/usr/bin/env bash
# Add a swap file so small instances (t3.micro/small) don't get OOM-killed
# during builds or package installs.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
require_root; require_supported_os; load_config

if swapon --show --noheadings | grep -q .; then
  ok "Swap already active: $(swapon --show --noheadings | awk '{print $1" "$3}' | tr '\n' ' ')"
  exit 0
fi

size="$SWAP_SIZE"
if [[ "$size" == "auto" ]]; then
  mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
  if (( mem_mb < 4000 )); then
    size="2G"
  else
    ok "RAM is ${mem_mb}MB; no swap needed (SWAP_SIZE=auto)"
    exit 0
  fi
fi

if [[ "$size" == "0" || -z "$size" ]]; then
  ok "Swap disabled (SWAP_SIZE=$SWAP_SIZE)"
  exit 0
fi

info "Creating ${size} swap file at /swapfile"
fallocate -l "$size" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$(numfmt --from=iec "$size" | awk '{print int($1/1048576)}')"
chmod 600 /swapfile
mkswap /swapfile >/dev/null
swapon /swapfile
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Prefer RAM; only swap under real pressure.
echo 'vm.swappiness = 10' > /etc/sysctl.d/60-ops-swap.conf
sysctl -q -p /etc/sysctl.d/60-ops-swap.conf
ok "Swap enabled (${size})"
