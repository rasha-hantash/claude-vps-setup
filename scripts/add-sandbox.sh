#!/usr/bin/env bash
# add-sandbox — Run on the VPS as the agent user. Installs Docker, builds the
# claude-sandbox image, drops a docker-running `claude` wrapper on PATH, and
# prepends the wrapper dir to ~/.bashrc.
#
# Expects (uploaded to ~ on the VPS before invocation):
#   ~/claude-sandbox.dockerfile
#   ~/claude-sandbox-wrapper.sh
#
# After running, opening a fresh shell:
#   `which claude`     → ~/.local/bin/sandbox/claude
#   `claude --version` → runs inside Docker

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Don't run this as root. Run as the agent user." >&2
  exit 1
fi

BUILD_DIR="$HOME/claude-sandbox"
WRAPPER_DIR="$HOME/.local/bin/sandbox"
DOCKERFILE_SRC="$HOME/claude-sandbox.dockerfile"
WRAPPER_SRC="$HOME/claude-sandbox-wrapper.sh"

for f in "$DOCKERFILE_SRC" "$WRAPPER_SRC"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing $f. Upload it to the VPS first." >&2
    exit 1
  fi
done

# 1. Install Docker via the official one-liner if not present.
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm /tmp/get-docker.sh
  sudo usermod -aG docker "$USER"
  echo "==> Docker installed."
  echo "    NOTE: 'docker' group membership only applies to new shells. If subsequent"
  echo "    docker commands hit 'permission denied', log out + back in and re-run."
fi

# 2. Build the claude-sandbox image. Use sudo for the build call so it works
#    even on a fresh install before the user's group membership has taken effect.
mkdir -p "$BUILD_DIR"
mv "$DOCKERFILE_SRC" "$BUILD_DIR/Dockerfile"
echo "==> Building claude-sandbox image (first build pulls Ubuntu base + Claude installer; few minutes)..."
sudo docker build -t claude-sandbox "$BUILD_DIR"

# 3. Install the wrapper to ~/.local/bin/sandbox/claude.
mkdir -p "$WRAPPER_DIR"
mv "$WRAPPER_SRC" "$WRAPPER_DIR/claude"
chmod +x "$WRAPPER_DIR/claude"

# 4. Prepend the sandbox dir to PATH in ~/.bashrc (idempotent).
BASHRC="$HOME/.bashrc"
if ! grep -q "claude-vps-sandbox-PATH" "$BASHRC" 2>/dev/null; then
  {
    echo ''
    echo '# claude-vps-sandbox-PATH — wraps `claude` to run inside Docker'
    echo 'export PATH="$HOME/.local/bin/sandbox:$PATH"'
  } >> "$BASHRC"
fi

echo ""
echo "==> Done. In a new shell:"
echo "      which claude         # should print $WRAPPER_DIR/claude"
echo "      claude --version     # runs inside Docker"
echo ""
echo "    To revert later, see /add-sandbox docs (Removing the sandbox)."
