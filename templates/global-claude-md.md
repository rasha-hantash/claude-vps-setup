# Global CLAUDE.md (VPS)

This box runs Claude Code over SSH, often from a phone via tmux. Conventions to follow on every project here.

## Sessions

- Always work inside a tmux session. If `$TMUX` is not set, ask the user to attach instead of running anything that takes more than a few seconds.
- Name sessions `{project}-{purpose}`, e.g. `atherton-paper-mcp`, `atherton-main`. Avoid generic names like `work` or `dev`.
- For parallel work on the same repo, create a `git worktree` and a separate tmux session per worktree. Don't run two Claudes in the same working tree.

## Long-running processes

- Dev servers, watchers, and anything that doesn't return go in their own tmux **window**, not a backgrounded shell job. The user needs to be able to detach the session and reattach later to see the output.
- If a command might take more than ~30 seconds, prefer running it in a window the user can switch to with prefix + n.

## Repos

- All cloned repos live under `~/projects/`.
- Authentication for `git push` is via per-repo SSH deploy key, not user credentials. If a push fails for auth reasons, ask before generating a new key.

## Don't

- Don't store production credentials on this box. It's for development only.
- Don't run `--dangerously-skip-permissions` unless the user explicitly asks for it for a specific session. Default to normal permission prompts.
