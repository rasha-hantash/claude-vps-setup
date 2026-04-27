#!/usr/bin/env bash
# Runs ON the VPS as root. Creates the agent user, hardens SSH, installs Tailscale and Claude Code.
#
# Required env:
#   TS_AUTH_KEY        Tailscale auth key (tskey-auth-...)
#
# Optional env:
#   LAPTOP_HOSTNAME    Tailscale hostname of the laptop (e.g., my-mbp.tail-abc.ts.net).
#                      If set, written into the agent's shell profile so `vps-sync-repo`
#                      finds the laptop without manual configuration.
#
# Expects (uploaded to /root/ before running):
#   /root/tmux.conf
#   /root/global-claude-md.md
#   /root/vps-clone           (helper script — installed to ~agent/.local/bin)
#   /root/vps-sync-repo       (helper script — installed to ~agent/.local/bin)

set -euo pipefail

: "${TS_AUTH_KEY:?TS_AUTH_KEY is required}"
LAPTOP_HOSTNAME="${LAPTOP_HOSTNAME:-}"

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
tailscale up --ssh --auth-key="$TS_AUTH_KEY" --accept-routes

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

echo "==> Installing GitHub CLI (gh) from official apt source..."
if ! command -v gh >/dev/null 2>&1; then
  KEYRING=/usr/share/keyrings/githubcli-archive-keyring.gpg
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /tmp/gh-keyring.gpg
  install -m 0644 /tmp/gh-keyring.gpg "$KEYRING"
  rm -f /tmp/gh-keyring.gpg
  ARCH="$(dpkg --print-architecture)"
  echo "deb [arch=$ARCH signed-by=$KEYRING] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh
fi

echo "==> Installing Claude Code (native installer)..."
sudo -u "$AGENT_USER" -i bash <<'AGENT_EOF'
set -euo pipefail
if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
fi
echo "Claude Code: $("$HOME/.local/bin/claude" --version)"
AGENT_EOF

echo "==> Dropping tmux config and global CLAUDE.md..."
if [[ -f /root/tmux.conf ]]; then
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 0644 /root/tmux.conf "/home/$AGENT_USER/.tmux.conf"
fi
if [[ -f /root/global-claude-md.md ]]; then
  sudo -u "$AGENT_USER" mkdir -p "/home/$AGENT_USER/.claude"
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 0644 /root/global-claude-md.md "/home/$AGENT_USER/.claude/CLAUDE.md"
fi

echo "==> Installing helper scripts to ~$AGENT_USER/.local/bin..."
sudo -u "$AGENT_USER" mkdir -p "/home/$AGENT_USER/.local/bin"
for helper in vps-clone vps-sync-repo; do
  if [[ -f "/root/$helper" ]]; then
    install -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "/root/$helper" "/home/$AGENT_USER/.local/bin/$helper"
  fi
done

echo "==> Configuring agent's shell profile..."
BASHRC="/home/$AGENT_USER/.bashrc"
# Append once (idempotent) — skip if our marker is already present.
if ! grep -q "claude-vps-setup" "$BASHRC" 2>/dev/null; then
  {
    echo ''
    echo '# --- claude-vps-setup ---'
    echo '# Default Claude Code to maximum reasoning effort on the VPS.'
    echo "alias claude='claude --effort max'"
    echo '# Ensure ~/.local/bin is on PATH.'
    echo 'if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then export PATH="$HOME/.local/bin:$PATH"; fi'
  } >> "$BASHRC"
  chown "$AGENT_USER:$AGENT_USER" "$BASHRC"
fi

# If LAPTOP_HOSTNAME was provided, persist it for vps-sync-repo to use.
if [[ -n "$LAPTOP_HOSTNAME" ]]; then
  if ! grep -q "^export LAPTOP_HOST=" "$BASHRC" 2>/dev/null; then
    echo "export LAPTOP_HOST=\"$LAPTOP_HOSTNAME\"" >> "$BASHRC"
    chown "$AGENT_USER:$AGENT_USER" "$BASHRC"
  fi
fi

echo "==> Bootstrap complete."
echo "Tailscale hostname:"
sudo -u "$AGENT_USER" tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//'
