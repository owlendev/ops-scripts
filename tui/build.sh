#!/usr/bin/env bash
# Builds the ops TUI for Linux amd64 and arm64 into ../bin/.
# push-and-run.sh copies bin/ to the server, so build here before pushing.
set -euo pipefail
cd "$(dirname "$0")"
version="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -ldflags "-s -w -X main.version=$version" -o "../bin/ops-linux-$arch" .
  echo "built bin/ops-linux-$arch ($version)"
done
