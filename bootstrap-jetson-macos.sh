#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CONFIG="$REPO_ROOT/config.local.sh"

HOST_ALIAS="${HOST_ALIAS:-jetson}"
JETSON_USER="${JETSON_USER:-Biglone}"
SSH_KEY_NAME="${SSH_KEY_NAME:-id_ed25519_jetson}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share/jetson-frp}"
FRP_VERSION="${FRP_VERSION:-latest}"
FRP_SERVER_ADDR="${FRP_SERVER_ADDR:-}"
FRP_SERVER_PORT="${FRP_SERVER_PORT:-7000}"
FRP_TOKEN="${FRP_TOKEN:-}"
FRP_VISITOR_NAME="${FRP_VISITOR_NAME:-company_ssh}"
FRP_SECRET_KEY="${FRP_SECRET_KEY:-}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
BIND_PORT="${BIND_PORT:-6000}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
SKIP_LAUNCH_AGENT="${SKIP_LAUNCH_AGENT:-0}"
SKIP_LAUNCH="${SKIP_LAUNCH:-0}"

MANAGED_BLOCK_START="# >>> jetson bootstrap >>>"
MANAGED_BLOCK_END="# <<< jetson bootstrap <<<"
LAUNCH_AGENT_ID="com.biglone.jetson-frpc"

if [[ -f "$LOCAL_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_CONFIG"
fi

step() {
  printf "\n==> %s\n" "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "Missing required value: $name. Set it in config.local.sh or via env." >&2
    exit 1
  fi
}

ensure_dir() {
  mkdir -p "$1"
}

get_frp_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    *) echo "Unsupported macOS architecture: $arch" >&2; exit 1 ;;
  esac
}

fetch_frp_release() {
  local arch="$1"
  local api_url
  if [[ "$FRP_VERSION" == "latest" ]]; then
    api_url="https://api.github.com/repos/fatedier/frp/releases/latest"
  else
    local tag="$FRP_VERSION"
    [[ "$tag" == v* ]] || tag="v$tag"
    api_url="https://api.github.com/repos/fatedier/frp/releases/tags/$tag"
  fi

  python3 - <<'PY' "$api_url" "$arch"
import json
import sys
from urllib.request import urlopen

api_url = sys.argv[1]
arch = sys.argv[2]

with urlopen(api_url) as response:
    data = json.load(response)

version = data["tag_name"].lstrip("v")
asset_name = f"frp_{version}_darwin_{arch}.tar.gz"
for asset in data["assets"]:
    if asset["name"] == asset_name:
        print(version)
        print(asset_name)
        print(asset["browser_download_url"])
        sys.exit(0)

raise SystemExit(f"Could not find asset {asset_name}")
PY
}

install_frpc() {
  local arch version asset_name download_url tarball extract_root
  arch="$(get_frp_arch)"
  mapfile -t release_info < <(fetch_frp_release "$arch")
  version="${release_info[0]}"
  asset_name="${release_info[1]}"
  download_url="${release_info[2]}"
  tarball="/tmp/$asset_name"
  extract_root
  extract_root="$(mktemp -d)"

  step "Downloading FRP $version ($arch)"
  curl -L "$download_url" -o "$tarball"

  step "Extracting FRP"
  tar -xzf "$tarball" -C "$extract_root"

  local frpc_source
  frpc_source="$(find "$extract_root" -name frpc -type f | head -n 1)"
  if [[ -z "$frpc_source" ]]; then
    echo "frpc binary not found after extracting $asset_name" >&2
    exit 1
  fi

  ensure_dir "$INSTALL_DIR"
  cp "$frpc_source" "$INSTALL_DIR/frpc"
  chmod +x "$INSTALL_DIR/frpc"

  rm -f "$tarball"
  rm -rf "$extract_root"
}

ensure_ssh_key() {
  local ssh_dir="$HOME/.ssh"
  local private_key="$ssh_dir/$SSH_KEY_NAME"
  local public_key="$private_key.pub"

  if [[ ! -f "$private_key" ]]; then
    step "Generating SSH key $SSH_KEY_NAME"
    ssh-keygen -t ed25519 -f "$private_key" -C "macos-jetson@$(scutil --get ComputerName 2>/dev/null || hostname)" -N ""
  else
    step "Reusing existing SSH key $SSH_KEY_NAME"
  fi
}

write_frpc_config() {
  cat > "$INSTALL_DIR/frpc-visitor-company-ssh.ini" <<EOF
[common]
server_addr = $FRP_SERVER_ADDR
server_port = $FRP_SERVER_PORT
token = $FRP_TOKEN

[${FRP_VISITOR_NAME}_visitor]
type = stcp
role = visitor
server_name = $FRP_VISITOR_NAME
sk = $FRP_SECRET_KEY
bind_addr = $BIND_ADDR
bind_port = $BIND_PORT
EOF
}

write_ssh_config() {
  local config_path="$HOME/.ssh/config"
  local key_path="$HOME/.ssh/$SSH_KEY_NAME"
  local block
  block="$(cat <<EOF
$MANAGED_BLOCK_START
Host $HOST_ALIAS
    HostName $BIND_ADDR
    Port $BIND_PORT
    User $JETSON_USER
    IdentityFile $key_path
    IdentitiesOnly yes
    ProxyCommand none
$MANAGED_BLOCK_END
EOF
)"

  if [[ ! -f "$config_path" ]]; then
    printf "%s\n" "$block" > "$config_path"
    return
  fi

  python3 - <<'PY' "$config_path" "$MANAGED_BLOCK_START" "$MANAGED_BLOCK_END" "$block"
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
start = re.escape(sys.argv[2])
end = re.escape(sys.argv[3])
block = sys.argv[4]
text = path.read_text()
pattern = re.compile(rf"(?ms)^{start}.*?^{end}\s*")

if pattern.search(text):
    updated = pattern.sub(block + "\n", text)
else:
    updated = text.rstrip() + "\n\n" + block + "\n" if text.strip() else block + "\n"

path.write_text(updated)
PY
}

write_launch_agent() {
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="$plist_dir/$LAUNCH_AGENT_ID.plist"
  ensure_dir "$plist_dir"

  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCH_AGENT_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/frpc</string>
        <string>-c</string>
        <string>$INSTALL_DIR/frpc-visitor-company-ssh.ini</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/frpc.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/frpc.err.log</string>
</dict>
</plist>
EOF

  launchctl unload "$plist_path" >/dev/null 2>&1 || true
  launchctl load "$plist_path"
}

start_frpc_now() {
  launchctl kickstart -k "gui/$(id -u)/$LAUNCH_AGENT_ID" >/dev/null 2>&1 || true
  sleep 2
}

copy_public_key_notice() {
  local pub_key_path="$HOME/.ssh/$SSH_KEY_NAME.pub"
  local pub_key
  pub_key="$(cat "$pub_key_path")"
  if command -v pbcopy >/dev/null 2>&1; then
    printf "%s" "$pub_key" | pbcopy
  fi

  step "Done"
  echo "Public key path: $pub_key_path"
  echo "Public key copied to clipboard: yes"
  echo
  echo "Add this public key to Jetson ~/.ssh/authorized_keys before first SSH from this device:"
  echo "$pub_key"
  echo
  echo "Next checks:"
  echo "  lsof -nP -iTCP:$BIND_PORT -sTCP:LISTEN"
  echo "  ssh -vvv $HOST_ALIAS"
}

require_command ssh
require_command ssh-keygen
require_command curl
require_command python3
require_value FRP_SERVER_ADDR "$FRP_SERVER_ADDR"
require_value FRP_TOKEN "$FRP_TOKEN"
require_value FRP_SECRET_KEY "$FRP_SECRET_KEY"

step "Preparing directories"
ensure_dir "$HOME/.ssh"
ensure_dir "$INSTALL_DIR"

if [[ "$SKIP_DOWNLOAD" != "1" ]]; then
  install_frpc
elif [[ ! -x "$INSTALL_DIR/frpc" ]]; then
  echo "SKIP_DOWNLOAD=1 but $INSTALL_DIR/frpc is missing" >&2
  exit 1
fi

ensure_ssh_key

step "Writing FRP config"
write_frpc_config

step "Writing SSH config block"
write_ssh_config

if [[ "$SKIP_LAUNCH_AGENT" != "1" ]]; then
  step "Registering LaunchAgent"
  write_launch_agent
fi

if [[ "$SKIP_LAUNCH" != "1" ]]; then
  step "Starting frpc"
  start_frpc_now
fi

copy_public_key_notice
