#!/usr/bin/env bash
# claude (sandbox wrapper) — runs Claude Code inside the claude-sandbox
# container with the current directory bind-mounted as /workspace.
#
# Installed by /add-sandbox to ~/.local/bin/sandbox/claude. With
# ~/.local/bin/sandbox prepended to PATH in ~/.bashrc, this wrapper
# shadows the host claude binary for all callers — including cove and
# tmux panes.
#
# Mounts only what Claude needs to operate against your account:
#   - $(pwd)                        → /workspace          (rw, your project)
#   - ~/.claude/.credentials.json   → /root/.claude/...   (ro, OAuth token)
#   - ~/.claude/CLAUDE.md           → /root/.claude/...   (ro, your global config)
#
# Things deliberately NOT mounted:
#   - ~/.ssh             — container can't push commits as you
#   - ~/.claude/hooks    — host hooks not exposed (preventing host execution)
#   - ~/.claude/projects — per-session state stays on host
#   - everything else under $HOME

set -euo pipefail

CRED="$HOME/.claude/.credentials.json"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
CWD="$(pwd)"

if [[ ! -f "$CRED" ]]; then
  echo "Missing $CRED. Run 'claude' once on the VPS host (not inside the sandbox)" >&2
  echo "to complete OAuth, then re-run." >&2
  exit 1
fi

# Refuse to mount overly broad directories — defeats the sandbox.
if [[ "$CWD" == "/" || "$CWD" == "$HOME" ]]; then
  echo "Refusing to mount $CWD as /workspace — too broad. cd into a specific repo first." >&2
  exit 1
fi

mounts=(-v "$CWD:/workspace")
mounts+=(-v "$CRED:/root/.claude/.credentials.json:ro")
[[ -f "$CLAUDE_MD" ]] && mounts+=(-v "$CLAUDE_MD:/root/.claude/CLAUDE.md:ro")

exec docker run --rm -it \
  "${mounts[@]}" \
  -w /workspace \
  claude-sandbox \
  claude --effort max --dangerously-skip-permissions "$@"
