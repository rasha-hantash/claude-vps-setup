#!/usr/bin/env bash
# vps-sync-repo — Run from inside a cloned repo on the VPS. Finds the matching
# repo on your laptop (by git remote URL) and rsyncs gitignored .claude/ files
# from there over the Tailscale link, so the VPS clone has the same permission
# grants and machine-local hooks you've already approved on the laptop.
#
# Required env:
#   LAPTOP_HOST                    Tailscale hostname of laptop (e.g., user@laptop.tail-abc.ts.net)
#
# Optional env:
#   LAPTOP_WORKSPACE               Workspace root to search on laptop (default: $HOME/workspace)
#   VPS_SYNC_INCLUDE_WORKTREES     If set to 1, also sync .claude/worktrees/. Off by default —
#                                  worktrees with their own node_modules / build artifacts can
#                                  push the payload into multi-GB territory and fill a small
#                                  VPS disk fast. Set this only when you actually want them.

set -euo pipefail

: "${LAPTOP_HOST:?LAPTOP_HOST is required. Add 'export LAPTOP_HOST=...' to your shell profile.}"
LAPTOP_WORKSPACE="${LAPTOP_WORKSPACE:-\$HOME/workspace}"

if ! ORIGIN_URL=$(git config --get remote.origin.url 2>/dev/null); then
  echo "Error: not in a git repo (no remote.origin.url set)." >&2
  exit 1
fi

echo "==> Verifying $LAPTOP_HOST is reachable..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$LAPTOP_HOST" true 2>/dev/null; then
  echo "Error: cannot reach $LAPTOP_HOST. Is the laptop awake and on Tailscale?" >&2
  exit 1
fi

echo "==> Searching for $ORIGIN_URL on laptop..."
LAPTOP_REPO=$(ssh "$LAPTOP_HOST" bash -s <<EOF || true
set -e
shopt -s nullglob 2>/dev/null || true
for gitdir in \$(find $LAPTOP_WORKSPACE -maxdepth 5 -name .git -type d 2>/dev/null | grep -v '/.claude/worktrees/' || true); do
  repo=\$(dirname "\$gitdir")
  remote=\$(git -C "\$repo" config --get remote.origin.url 2>/dev/null || true)
  if [ "\$remote" = "$ORIGIN_URL" ]; then
    echo "\$repo"
    exit 0
  fi
done
exit 1
EOF
)

if [[ -z "$LAPTOP_REPO" ]]; then
  echo "==> No matching repo found on laptop. Skipping sync (the VPS clone will work — you'll just re-grant permissions interactively as Claude prompts)."
  exit 0
fi

echo "==> Found: $LAPTOP_HOST:$LAPTOP_REPO"

GITIGNORED=$(ssh "$LAPTOP_HOST" "cd '$LAPTOP_REPO' && git ls-files --others --ignored --exclude-standard .claude/ 2>/dev/null" || true)

# Skip .claude/worktrees/ by default — they tend to contain entire working copies with
# node_modules and build artifacts, which can balloon to several GB and fill a small VPS disk.
# Users who genuinely want their worktrees synced can set VPS_SYNC_INCLUDE_WORKTREES=1.
if [[ -n "$GITIGNORED" && "${VPS_SYNC_INCLUDE_WORKTREES:-0}" != "1" ]]; then
  WORKTREE_COUNT=$(echo "$GITIGNORED" | grep -c '^\.claude/worktrees/' || true)
  if [[ "$WORKTREE_COUNT" -gt 0 ]]; then
    echo "==> Skipping $WORKTREE_COUNT files under .claude/worktrees/ (set VPS_SYNC_INCLUDE_WORKTREES=1 to include)."
    GITIGNORED=$(echo "$GITIGNORED" | grep -v '^\.claude/worktrees/' || true)
  fi
fi

if [[ -z "$GITIGNORED" ]]; then
  echo "==> Nothing to sync (laptop has no gitignored .claude/ files, or all of them were under worktrees and were skipped)."
  exit 0
fi

echo "==> Syncing:"
echo "$GITIGNORED" | sed 's/^/    /'

mkdir -p .claude
echo "$GITIGNORED" | rsync -av --info=progress2 --files-from=- "$LAPTOP_HOST:$LAPTOP_REPO/" .

echo "==> Done."
