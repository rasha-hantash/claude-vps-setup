#!/usr/bin/env bash
# Runs ON the VPS as root. Creates the agent user, hardens SSH, installs Tailscale and Claude Code.
#
# Required env:
#   TS_AUTH_KEY    Tailscale auth key (tskey-auth-...)
#
# Expects (uploaded to /root/ before running):
#   /root/tmux.conf
#   /root/global-claude-md.md

set -euo pipefail

: "${TS_AUTH_KEY:?TS_AUTH_KEY is required}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root." >&2
  exit 1
fi

AGENT_USER="agent"

echo "==> Updating apt and installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  zsh git curl ca-certificates gnupg ufw tmux build-essential jq unzip

echo "==> Creating user '$AGENT_USER'..."
if ! id "$AGENT_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$AGENT_USER"
  usermod -aG sudo "$AGENT_USER"
  echo "$AGENT_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$AGENT_USER"
  chmod 440 "/etc/sudoers.d/$AGENT_USER"
fi

echo "==> Installing root's authorized SSH key for '$AGENT_USER'..."
mkdir -p "/home/$AGENT_USER/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "/home/$AGENT_USER/.ssh/authorized_keys"
fi
chown -R "$AGENT_USER:$AGENT_USER" "/home/$AGENT_USER/.ssh"
chmod 700 "/home/$AGENT_USER/.ssh"
chmod 600 "/home/$AGENT_USER/.ssh/authorized_keys" 2>/dev/null || true

echo "==> Installing Tailscale..."
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
tailscale up --ssh --authkey="$TS_AUTH_KEY" --accept-routes

echo "==> Configuring UFW (allow Tailscale; deny everything else by default)..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
# NOTE: We are NOT opening port 22 to the public. SSH goes over Tailscale only.
ufw --force enable

echo "==> Hardening sshd (no root login, no password auth)..."
sed -i \
  -e 's|^#\?PermitRootLogin.*|PermitRootLogin no|' \
  -e 's|^#\?PasswordAuthentication.*|PasswordAuthentication no|' \
  /etc/ssh/sshd_config
systemctl reload ssh

echo "==> Installing Node via nvm for '$AGENT_USER'..."
sudo -u "$AGENT_USER" -i bash <<'AGENT_EOF'
set -euo pipefail
if [[ ! -d "$HOME/.nvm" ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
source "$NVM_DIR/nvm.sh"
nvm install --lts
nvm alias default 'lts/*'
echo "Node: $(node --version), npm: $(npm --version)"

echo "==> Installing Claude Code..."
npm install -g @anthropic-ai/claude-code
AGENT_EOF

echo "==> Dropping tmux config and global CLAUDE.md..."
if [[ -f /root/tmux.conf ]]; then
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 0644 /root/tmux.conf "/home/$AGENT_USER/.tmux.conf"
fi
if [[ -f /root/global-claude-md.md ]]; then
  sudo -u "$AGENT_USER" mkdir -p "/home/$AGENT_USER/.claude"
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 0644 /root/global-claude-md.md "/home/$AGENT_USER/.claude/CLAUDE.md"
fi

echo "==> Bootstrap complete."
echo "Tailscale hostname:"
sudo -u "$AGENT_USER" tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//'
