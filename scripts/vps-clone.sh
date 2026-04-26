#!/usr/bin/env bash
# vps-clone — Clones a GitHub repo on the VPS, then runs vps-sync-repo to pull
# gitignored .claude/ files from the matching repo on your laptop.
#
# Usage: vps-clone <owner/repo>
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

echo "==> Cloning $REPO_SPEC..."
gh repo clone "$REPO_SPEC"

REPO_NAME="${REPO_SPEC##*/}"
cd "$REPO_NAME"

echo "==> Running vps-sync-repo to pull gitignored .claude/ files..."
exec vps-sync-repo
