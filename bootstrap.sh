#!/usr/bin/env bash
# Prepare a fresh Ubuntu/Debian server by running the enabled modules in modules/.
# Safe to re-run.
set -euo pipefail

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPS_ROOT
# shellcheck source=lib/common.sh
. "$OPS_ROOT/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Options:
  -c, --config FILE    Client config file (overrides config/default.env)
  -o, --only LIST      Run only these modules, comma separated (ignores ENABLE_* flags)
  -s, --skip LIST      Skip these modules, comma separated
  -l, --list           List modules and whether they are enabled, then exit
  -h, --help           Show this help

Examples:
  sudo $0 -c examples/web-server.env
  sudo $0 --only firewall,ssh-hardening
  sudo $0 --skip swap
EOF
}

ONLY=""
SKIP=""
LIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config) [[ -n "${2:-}" ]] || die "--config needs a file"
                 OPS_CONFIG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
                 export OPS_CONFIG; shift 2 ;;
    -o|--only)   ONLY="${2:-}"; shift 2 ;;
    -s|--skip)   SKIP="${2:-}"; shift 2 ;;
    -l|--list)   LIST=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "Unknown option: $1" ;;
  esac
done

load_config

module_name() { local b; b="$(basename "$1" .sh)"; echo "${b#*-}"; }
enable_var()  { echo "ENABLE_$(echo "$1" | tr 'a-z-' 'A-Z_')"; }
in_list()     { [[ ",$2," == *",$1,"* ]]; }

MODULES=("$OPS_ROOT"/modules/*.sh)

if (( LIST )); then
  printf '%-20s %-26s %s\n' MODULE VARIABLE ENABLED
  for f in "${MODULES[@]}"; do
    n="$(module_name "$f")"; v="$(enable_var "$n")"
    printf '%-20s %-26s %s\n' "$n" "$v" "${!v:-no}"
  done
  exit 0
fi

# Reject typos in --only / --skip before touching anything.
all_names=","
for f in "${MODULES[@]}"; do all_names+="$(module_name "$f"),"; done
for n in ${ONLY//,/ } ${SKIP//,/ }; do
  [[ "$all_names" == *",$n,"* ]] || die "Unknown module '$n'. Use --list to see modules."
done

require_root
require_supported_os

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

section "ops-scripts bootstrap — $(hostname) — $(date -Is)"
info "OS: $OS_ID $OS_VERSION ($OS_CODENAME), config: ${OPS_CONFIG:-defaults only}"

ran=()
skipped=()
start=$(date +%s)

for f in "${MODULES[@]}"; do
  n="$(module_name "$f")"
  v="$(enable_var "$n")"
  if [[ -n "$ONLY" ]]; then
    in_list "$n" "$ONLY" || continue
  elif in_list "$n" "$SKIP" || ! is_true "${!v:-no}"; then
    skipped+=("$n")
    continue
  fi

  section "Module: $n"
  bash "$f" || die "Module '$n' failed. Fix the problem and re-run; finished modules will be skipped quickly."
  ran+=("$n")
done

section "Summary"
ok "Ran: ${ran[*]:-none}"
[[ ${#skipped[@]} -gt 0 ]] && info "Skipped: ${skipped[*]}"
info "Finished in $(( $(date +%s) - start ))s. Log: $LOG_FILE"

if [[ -z "$ONLY" ]] && is_true "$RUN_AUDIT"; then
  bash "$OPS_ROOT/checks/audit.sh" || true
fi

if [[ -f /var/run/reboot-required ]]; then
  if is_true "$REBOOT_IF_REQUIRED"; then
    warn "Reboot required; rebooting in 1 minute."
    shutdown -r +1 "ops-scripts: rebooting to finish updates" || true
  else
    warn "A reboot is required to finish updates (e.g. new kernel): sudo reboot"
  fi
fi
