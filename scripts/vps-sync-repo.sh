#!/usr/bin/env bash
# vps-sync-repo — Run from inside a cloned repo on the VPS. Finds the matching
# repo on your laptop (by git remote URL) and rsyncs gitignored .claude/ files
# from there over the Tailscale link, so the VPS clone has the same permission
# grants and machine-local hooks you've already approved on the laptop.
#
# Common build/cache directories (node_modules, dist, target, .next, etc.) are
# filtered out of the file list before rsync — see EXCLUDE_DIRS_REGEX below.
# This keeps worktree syncs reasonable on small VPS disks; a build can still be
# regenerated from source on the VPS.
#
# Required env:
#   LAPTOP_HOST                    Tailscale hostname of laptop (e.g., user@laptop.tail-abc.ts.net)
#
# Optional env:
#   LAPTOP_WORKSPACE               Workspace root to search on laptop (default: $HOME/workspace)

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

# Filter out common build/cache directories. These match anywhere in the path so
# `.claude/worktrees/<name>/node_modules/...` is excluded just as `.claude/.../target/...`
# would be. Conservative list: well-known names that are almost always build outputs.
# To extend, add directory names (regex-escaped) inside the parentheses below.
EXCLUDE_DIRS_REGEX='/(node_modules|dist|build|target|out|coverage|\.next|\.turbo|\.cache|\.vercel|\.svelte-kit|\.nuxt|\.parcel-cache|\.vite|__pycache__|\.venv|\.pytest_cache|\.mypy_cache)/'

if [[ -n "$GITIGNORED" ]]; then
  EXCLUDED_COUNT=$(echo "$GITIGNORED" | grep -cE "$EXCLUDE_DIRS_REGEX" || true)
  if [[ "$EXCLUDED_COUNT" -gt 0 ]]; then
    echo "==> Excluding $EXCLUDED_COUNT files under build/cache dirs (node_modules, dist, target, .next, etc.)."
    GITIGNORED=$(echo "$GITIGNORED" | grep -vE "$EXCLUDE_DIRS_REGEX" || true)
  fi
fi

if [[ -z "$GITIGNORED" ]]; then
  echo "==> Nothing to sync (no gitignored .claude/ files left after filtering)."
  exit 0
fi

SYNC_COUNT=$(echo "$GITIGNORED" | wc -l | tr -d ' ')
echo "==> Syncing $SYNC_COUNT files:"
if [[ "$SYNC_COUNT" -gt 20 ]]; then
  echo "$GITIGNORED" | head -20 | sed 's/^/    /'
  echo "    ... ($((SYNC_COUNT - 20)) more)"
else
  echo "$GITIGNORED" | sed 's/^/    /'
fi

mkdir -p .claude
echo "$GITIGNORED" | rsync -av --info=progress2 --files-from=- "$LAPTOP_HOST:$LAPTOP_REPO/" .

echo "==> Done."
