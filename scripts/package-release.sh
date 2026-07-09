#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 v0.1.0" >&2
  exit 1
fi

VERSION="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
PACKAGE_BASENAME="jetson-bootstrap-toolkit-$VERSION"
ARCHIVE_PATH="$DIST_DIR/$PACKAGE_BASENAME.zip"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required to package a release" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE_PATH"

git -C "$REPO_ROOT" archive \
  --format=zip \
  --output="$ARCHIVE_PATH" \
  --prefix="$PACKAGE_BASENAME/" \
  HEAD

echo "$ARCHIVE_PATH"
