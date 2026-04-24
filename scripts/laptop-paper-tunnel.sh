#!/usr/bin/env bash
# Runs on the user's LAPTOP. Starts an autossh reverse tunnel from laptop:29979 -> vps:29979,
# so the VPS's loopback can reach Paper Desktop's MCP server running on the laptop.
# Also installs a launchd plist (macOS) or systemd user service (Linux) so the tunnel survives reboots.
#
# Usage: ./laptop-paper-tunnel.sh <vps-tailscale-hostname> [ssh-user]

set -euo pipefail

VPS_HOSTNAME="${1:-}"
SSH_USER="${2:-agent}"

if [[ -z "$VPS_HOSTNAME" ]]; then
  echo "Usage: $0 <vps-tailscale-hostname> [ssh-user]" >&2
  exit 1
fi

if ! command -v autossh >/dev/null 2>&1; then
  echo "autossh not found. Install via: brew install autossh (macOS) or apt install autossh (Linux)" >&2
  exit 1
fi

# Sanity check: Paper's MCP must be reachable locally.
if ! curl -sS -o /dev/null --max-time 3 http://127.0.0.1:29979/mcp; then
  echo "WARNING: http://127.0.0.1:29979/mcp is not responding. Make sure Paper Desktop is open with a file." >&2
  echo "Continuing anyway — the tunnel will work once Paper starts." >&2
fi

# Sanity check: SSH to VPS works.
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$VPS_HOSTNAME" true 2>/dev/null; then
  echo "ERROR: cannot SSH to $SSH_USER@$VPS_HOSTNAME. Fix Tailscale + SSH first." >&2
  exit 1
fi

OS="$(uname -s)"

if [[ "$OS" == "Darwin" ]]; then
  PLIST_PATH="$HOME/Library/LaunchAgents/com.claude-vps-setup.paper-tunnel.plist"
  TEMPLATE_PATH="$(cd "$(dirname "$0")/../templates" && pwd)/autossh.plist"

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
    -e "s|{{HOME}}|$HOME|g" \
    "$TEMPLATE_PATH" > "$PLIST_PATH"

  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"
  echo "Loaded launchd agent at $PLIST_PATH"
  echo "Tunnel will start now and on every login."

elif [[ "$OS" == "Linux" ]]; then
  UNIT_DIR="$HOME/.config/systemd/user"
  UNIT_PATH="$UNIT_DIR/paper-tunnel.service"
  AUTOSSH_BIN="$(command -v autossh)"

  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=autossh reverse tunnel for Paper Desktop MCP
After=network-online.target

[Service]
Environment=AUTOSSH_GATETIME=0
ExecStart=$AUTOSSH_BIN -M 0 -N \\
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \\
  -R 29979:127.0.0.1:29979 \\
  $SSH_USER@$VPS_HOSTNAME
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload
  systemctl --user enable --now paper-tunnel.service
  echo "Installed and started systemd user unit at $UNIT_PATH"
else
  echo "Unsupported OS: $OS. Run autossh manually:" >&2
  echo "  autossh -M 0 -N -R 29979:127.0.0.1:29979 $SSH_USER@$VPS_HOSTNAME" >&2
  exit 1
fi

echo
echo "Verifying tunnel from VPS..."
sleep 3
if ssh "$SSH_USER@$VPS_HOSTNAME" "curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 http://127.0.0.1:29979/mcp"; then
  echo "Tunnel is live. The VPS can now reach Paper's MCP at its own 127.0.0.1:29979."
else
  echo "Tunnel may not be ready yet. Wait a few seconds and re-test:" >&2
  echo "  ssh $SSH_USER@$VPS_HOSTNAME \"curl -v http://127.0.0.1:29979/mcp\"" >&2
fi
