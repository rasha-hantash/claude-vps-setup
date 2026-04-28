#!/usr/bin/env bash
# vps-clone — Clones a GitHub repo on the VPS into ~/workspace/<repo> (or
# wherever VPS_REPOS_DIR points), then runs vps-sync-repo to pull gitignored
# .claude/ files from the matching repo on your laptop.
#
# Usage: vps-clone <owner/repo>
#
# Optional env:
#   VPS_REPOS_DIR    Where to clone repos. Default: $HOME/workspace.
#                    Mirrors the laptop convention used by vps-sync-repo's
#                    LAPTOP_WORKSPACE so layouts match across machines.
#
# Requires `gh` to be authenticated and `vps-sync-repo` on PATH.

set -euo pipefail

REPO_SPEC="${1:-}"
if [[ -z "$REPO_SPEC" ]]; then
  echo "usage: vps-clone <owner/repo>" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found." >&2
  exit 1
fi

if ! command -v vps-sync-repo >/dev/null 2>&1; then
  echo "Error: vps-sync-repo not on PATH. Did the bootstrap finish?" >&2
  exit 1
fi

REPOS_DIR="${VPS_REPOS_DIR:-$HOME/workspace}"
mkdir -p "$REPOS_DIR"
cd "$REPOS_DIR"

echo "==> Cloning $REPO_SPEC into $REPOS_DIR..."
gh repo clone "$REPO_SPEC"

REPO_NAME="${REPO_SPEC##*/}"
cd "$REPO_NAME"

echo "==> Running vps-sync-repo to pull gitignored .claude/ files..."
exec vps-sync-repo
