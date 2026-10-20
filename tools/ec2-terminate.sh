#!/usr/bin/env bash
# Run FROM YOUR MACHINE. Destroys what ec2-launch.sh created for NAME:
# the instance(s), their Elastic IP(s), and the NAME-sg security group.
#
#   tools/ec2-terminate.sh --name acme-web
set -euo pipefail

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$OPS_ROOT/lib/common.sh"

usage() {
  cat <<EOF
Usage: $0 --name NAME [--region REGION] [--yes]

Only touches resources tagged ManagedBy=ops-scripts and Name=NAME.
  --yes   Don't ask for confirmation
EOF
}

NAME=""; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   NAME="$2"; shift 2 ;;
    --region) export AWS_REGION="$2"; shift 2 ;;
    --yes)    YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done
[[ -n "$NAME" ]] || { usage >&2; exit 1; }

filters=("Name=tag:Name,Values=$NAME" "Name=tag:ManagedBy,Values=ops-scripts")

INSTANCES=$(aws ec2 describe-instances \
  --filters "${filters[@]}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
EIPS=$(aws ec2 describe-addresses --filters "${filters[@]}" --query 'Addresses[].AllocationId' --output text)
SGS=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$NAME-sg" "Name=tag:ManagedBy,Values=ops-scripts" \
  --query 'SecurityGroups[].GroupId' --output text)

if [[ -z "$INSTANCES$EIPS$SGS" ]]; then
  ok "Nothing found for '$NAME' (region ${AWS_REGION:-$(aws configure get region)})"
  exit 0
fi

section "Will permanently delete (region ${AWS_REGION:-$(aws configure get region)}):"
[[ -n "$INSTANCES" ]] && echo "  Instances:       $INSTANCES  (root volumes are deleted too)"
[[ -n "$EIPS" ]]      && echo "  Elastic IPs:     $EIPS"
[[ -n "$SGS" ]]       && echo "  Security groups: $SGS"

if (( ! YES )); then
  printf '\nType the name "%s" to confirm: ' "$NAME"
  read -r answer
  [[ "$answer" == "$NAME" ]] || die "Aborted."
fi

if [[ -n "$INSTANCES" ]]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $INSTANCES >/dev/null
  info "Terminating $INSTANCES (waiting...)"
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $INSTANCES
  ok "Instances terminated"
fi

for a in $EIPS; do
  assoc=$(aws ec2 describe-addresses --allocation-ids "$a" --query 'Addresses[0].AssociationId' --output text)
  [[ "$assoc" != "None" ]] && aws ec2 disassociate-address --association-id "$assoc" || true
  aws ec2 release-address --allocation-id "$a"
  ok "Released Elastic IP $a"
done

for sg in $SGS; do
  if aws ec2 delete-security-group --group-id "$sg" 2>/dev/null; then
    ok "Deleted security group $sg"
  else
    warn "Could not delete $sg (still in use by something else?)"
  fi
done
