#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_NAME="$(uname -s)"

case "$OS_NAME" in
  Darwin)
    exec "$SCRIPT_DIR/bootstrap-jetson-macos.sh" "$@"
    ;;
  Linux)
    echo "Linux bootstrap is not implemented yet. Use macOS or Windows for now." >&2
    exit 1
    ;;
  *)
    echo "Unsupported OS: $OS_NAME" >&2
    exit 1
    ;;
esac
