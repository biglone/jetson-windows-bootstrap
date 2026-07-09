#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <public-key-file> [ssh-host-alias]" >&2
  echo "Example: $0 ~/.ssh/id_ed25519_jetson.pub jetson" >&2
  exit 1
fi

PUBKEY_FILE="$1"
SSH_HOST="${2:-jetson}"

if [[ ! -f "$PUBKEY_FILE" ]]; then
  echo "Public key file not found: $PUBKEY_FILE" >&2
  exit 1
fi

if [[ ! -s "$PUBKEY_FILE" ]]; then
  echo "Public key file is empty: $PUBKEY_FILE" >&2
  exit 1
fi

ssh "$SSH_HOST" 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; key=$(cat); grep -qxF "$key" ~/.ssh/authorized_keys || printf "%s\n" "$key" >> ~/.ssh/authorized_keys' < "$PUBKEY_FILE"

echo "Public key appended to ~/.ssh/authorized_keys on $SSH_HOST"
