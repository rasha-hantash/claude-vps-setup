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
# LAPTOP_WORKSPACE may be unset here; the laptop side defaults it to
# $HOME/workspace (expanded on the laptop, not on the VPS).
LAPTOP_WORKSPACE="${LAPTOP_WORKSPACE:-}"

if ! ORIGIN_URL=$(git config --get remote.origin.url 2>/dev/null); then
  echo "Error: not in a git repo (no remote.origin.url set)." >&2
  exit 1
fi

echo "==> Verifying $LAPTOP_HOST is reachable..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$LAPTOP_HOST" true 2>/dev/null; then
  echo "Error: cannot reach $LAPTOP_HOST. Is the laptop awake and on Tailscale?" >&2
  exit 1
fi

# Match by NORMALIZED remote URL, not raw string. gh-cloned VPS repos use the
# HTTPS form (https://github.com/owner/repo.git) while laptop clones are often
# SSH (git@github.com:owner/repo.git); a raw-string compare never matches those,
# so the sync was silently skipped. normalize_remote_url() collapses scp/https/
# ssh forms (and userinfo, port, trailing slash, .git, case) to a canonical
# host/owner/repo. It also runs on the laptop (bash 3.2 on macOS) below, so keep
# the two copies behaviorally identical and do NOT convert the scp-form colon
# with a ${var/:/...} substitution — bash 3.2 inserts a literal backslash into
# the replacement.
normalize_remote_url() {
  local u="$1" hostport host path
  u="${u%/}"
  u="${u%.git}"
  if [[ "$u" == *://* ]]; then
    u="${u#*://}"
  else
    u="${u%%:*}/${u#*:}"
  fi
  u="${u#*@}"
  hostport="${u%%/*}"
  host="${hostport%%:*}"
  path="${u#*/}"
  printf '%s' "${host}/${path}" | tr '[:upper:]' '[:lower:]'
}

echo "==> Searching for $ORIGIN_URL on laptop..."
NORM_ORIGIN="$(normalize_remote_url "$ORIGIN_URL")"
LAPTOP_REPO=$(ssh "$LAPTOP_HOST" bash -s "$NORM_ORIGIN" "$LAPTOP_WORKSPACE" <<'EOF' || true
set -e
NORM_ORIGIN="$1"
WS="${2:-$HOME/workspace}"
normalize_remote_url() {
  local u="$1" hostport host path
  u="${u%/}"
  u="${u%.git}"
  if [[ "$u" == *://* ]]; then
    u="${u#*://}"
  else
    u="${u%%:*}/${u#*:}"
  fi
  u="${u#*@}"
  hostport="${u%%/*}"
  host="${hostport%%:*}"
  path="${u#*/}"
  printf '%s' "${host}/${path}" | tr '[:upper:]' '[:lower:]'
}
shopt -s nullglob 2>/dev/null || true
for gitdir in $(find "$WS" -maxdepth 5 -name .git -type d 2>/dev/null | grep -v '/.claude/worktrees/' || true); do
  repo=$(dirname "$gitdir")
  remote=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)
  [ -z "$remote" ] && continue
  if [ "$(normalize_remote_url "$remote")" = "$NORM_ORIGIN" ]; then
    echo "$repo"
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
