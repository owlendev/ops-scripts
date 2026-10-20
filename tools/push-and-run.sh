#!/usr/bin/env bash
# Run FROM YOUR MACHINE: copy this repo to a server over SSH and run bootstrap.sh there.
#
#   tools/push-and-run.sh -i ~/.ssh/client.pem -c clients/acme.env ubuntu@203.0.113.10
#   tools/push-and-run.sh -i key.pem ubuntu@host -- --only firewall,ssh-hardening
set -euo pipefail

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$OPS_ROOT/lib/common.sh"

REMOTE_DIR=/opt/ops-scripts

usage() {
  cat <<EOF
Usage: $0 [-i KEY] [-p PORT] [-c CONFIG] user@host [-- bootstrap options]

  -i KEY      SSH private key (e.g. the EC2 .pem file)
  -p PORT     SSH port (default 22)
  -c CONFIG   Client config file to upload and use
  --          Everything after this is passed to bootstrap.sh

The repo is copied to $REMOTE_DIR on the server, so you can later run
'sudo $REMOTE_DIR/checks/audit.sh' there.
EOF
}

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
config=""
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) ssh_opts+=(-i "$2"); shift 2 ;;
    -p) ssh_opts+=(-p "$2"); shift 2 ;;
    -c) config="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; die "Unknown option: $1" ;;
    *)  target="$1"; shift ;;
  esac
done
[[ -n "$target" ]] || { usage >&2; exit 1; }
[[ -z "$config" || -f "$config" ]] || die "Config not found: $config"

remote_args=()
[[ -n "$config" ]] && remote_args+=(-c "$REMOTE_DIR/config/host.env")
remote_args+=("$@")

info "Copying ops-scripts to $target:$REMOTE_DIR"
# COPYFILE_DISABLE stops macOS tar from adding ._* files.
COPYFILE_DISABLE=1 tar -C "$OPS_ROOT" -czf - --exclude=.git --exclude='*.pem' . \
  | ssh "${ssh_opts[@]}" "$target" \
      "sudo rm -rf $REMOTE_DIR && sudo mkdir -p $REMOTE_DIR && sudo tar -xzf - -C $REMOTE_DIR --no-same-owner"

if [[ -n "$config" ]]; then
  ssh "${ssh_opts[@]}" "$target" "sudo tee $REMOTE_DIR/config/host.env >/dev/null && sudo chmod 600 $REMOTE_DIR/config/host.env" < "$config"
fi

quoted=""
for a in ${remote_args[@]+"${remote_args[@]}"}; do quoted+=" $(printf '%q' "$a")"; done

info "Running bootstrap on $target"
ssh -t "${ssh_opts[@]}" "$target" "sudo bash $REMOTE_DIR/bootstrap.sh$quoted"
