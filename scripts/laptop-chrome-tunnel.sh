#!/usr/bin/env bash
# Runs on the user's LAPTOP. Starts an autossh reverse tunnel from
# laptop:<chrome-mcp-port> -> vps:<chrome-mcp-port>, so the VPS's loopback
# can reach the claude-in-chrome MCP server running on the laptop.
# Also installs a launchd plist (macOS) or systemd user service (Linux)
# so the tunnel survives reboots.
#
# Usage: ./laptop-chrome-tunnel.sh <vps-tailscale-hostname> <chrome-mcp-port> [ssh-user]

set -euo pipefail

VPS_HOSTNAME="${1:-}"
PORT="${2:-}"
SSH_USER="${3:-agent}"

if [[ -z "$VPS_HOSTNAME" || -z "$PORT" ]]; then
  echo "Usage: $0 <vps-tailscale-hostname> <chrome-mcp-port> [ssh-user]" >&2
  exit 1
fi

if ! command -v autossh >/dev/null 2>&1; then
  echo "autossh not found. Install via: brew install autossh (macOS) or apt install autossh (Linux)" >&2
  exit 1
fi

# Sanity check: chrome MCP must be reachable locally on the laptop.
if ! curl -sS -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
  echo "WARNING: nothing listening on http://127.0.0.1:$PORT — make sure Chrome + claude-in-chrome extension are running." >&2
  echo "Continuing anyway — tunnel will work once the MCP is up." >&2
fi

# Sanity check: SSH to VPS works.
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$VPS_HOSTNAME" true 2>/dev/null; then
  echo "ERROR: cannot SSH to $SSH_USER@$VPS_HOSTNAME. Fix Tailscale + SSH first." >&2
  exit 1
fi

OS="$(uname -s)"

if [[ "$OS" == "Darwin" ]]; then
  PLIST_PATH="$HOME/Library/LaunchAgents/com.claude-vps-setup.chrome-tunnel.plist"
  TEMPLATE_PATH="$(cd "$(dirname "$0")/../templates" && pwd)/autossh-chrome.plist"

  if [[ ! -f "$TEMPLATE_PATH" ]]; then
    echo "Template not found at $TEMPLATE_PATH" >&2
    exit 1
  fi

  AUTOSSH_BIN="$(command -v autossh)"
  SSH_BIN="$(command -v ssh)"

  mkdir -p "$(dirname "$PLIST_PATH")"
  sed \
    -e "s|{{AUTOSSH_BIN}}|$AUTOSSH_BIN|g" \
    -e "s|{{SSH_BIN}}|$SSH_BIN|g" \
    -e "s|{{SSH_USER}}|$SSH_USER|g" \
    -e "s|{{VPS_HOSTNAME}}|$VPS_HOSTNAME|g" \
    -e "s|{{PORT}}|$PORT|g" \
    -e "s|{{HOME}}|$HOME|g" \
    "$TEMPLATE_PATH" > "$PLIST_PATH"

  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"
  echo "Loaded launchd agent at $PLIST_PATH"
  echo "Tunnel will start now and on every login."

elif [[ "$OS" == "Linux" ]]; then
  UNIT_DIR="$HOME/.config/systemd/user"
  UNIT_PATH="$UNIT_DIR/chrome-tunnel.service"
  AUTOSSH_BIN="$(command -v autossh)"

  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=autossh reverse tunnel for claude-in-chrome MCP
After=network-online.target

[Service]
Environment=AUTOSSH_GATETIME=0
ExecStart=$AUTOSSH_BIN -M 0 -N \\
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \\
  -R $PORT:127.0.0.1:$PORT \\
  $SSH_USER@$VPS_HOSTNAME
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload
  systemctl --user enable --now chrome-tunnel.service
  echo "Installed and started systemd user unit at $UNIT_PATH"
else
  echo "Unsupported OS: $OS. Run autossh manually:" >&2
  echo "  autossh -M 0 -N -R $PORT:127.0.0.1:$PORT $SSH_USER@$VPS_HOSTNAME" >&2
  exit 1
fi

echo
echo "Verifying tunnel from VPS..."
sleep 3
if ssh "$SSH_USER@$VPS_HOSTNAME" "curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 http://127.0.0.1:$PORT/"; then
  echo "Tunnel is live. The VPS can now reach claude-in-chrome's MCP at its own 127.0.0.1:$PORT."
else
  echo "Tunnel may not be ready yet. Wait a few seconds and re-test:" >&2
  echo "  ssh $SSH_USER@$VPS_HOSTNAME \"curl -v http://127.0.0.1:$PORT/\"" >&2
fi
