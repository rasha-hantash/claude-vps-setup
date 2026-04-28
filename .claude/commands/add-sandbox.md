# /add-sandbox

Wire up a Docker-based sandbox on the VPS so that running `claude` execs Claude Code inside a container instead of on the host. Inside the container, `--dangerously-skip-permissions` is the default — the container is the safety boundary, not the LLM.

## Before you start

1. Read `./.setup-state.json`. If it doesn't exist, tell the user to run `/setup` first and stop.
2. Confirm the VPS is reachable: `ssh agent@<tailscale-hostname> true`.
3. Confirm the VPS has `~/.claude/.credentials.json` already (the user must have completed claude OAuth on the VPS once). Probe: `ssh agent@<host> 'test -f ~/.claude/.credentials.json'`. If missing, tell them to run `ssh agent@<host> -t claude` first to complete OAuth, then re-invoke `/add-sandbox`.

## Confirm with the user

This changes the `claude` command on the VPS to run inside Docker. Specifically:

- Installs Docker on the VPS (~500 MB – 1 GB)
- Builds a small `claude-sandbox` image with the native Claude Code installer
- Replaces `claude` on PATH with a wrapper that bind-mounts `$(pwd)` and the credentials file into the container
- Inside the sandbox, claude runs with `--effort max --dangerously-skip-permissions`
- Filesystem access **only** to the working directory + read-only credentials. No SSH keys, no host hooks, no other repos.
- Network access is **not** restricted. Egress works as normal.

Get a yes before proceeding.

## Run it

```
scp scripts/add-sandbox.sh                 agent@<host>:~/add-sandbox.sh
scp templates/claude-sandbox.dockerfile    agent@<host>:~/claude-sandbox.dockerfile
scp templates/claude-sandbox-wrapper.sh    agent@<host>:~/claude-sandbox-wrapper.sh
ssh agent@<host> bash ~/add-sandbox.sh
```

Substitute `<host>` with `vpsTailscaleHostname` from `.setup-state.json`.

The script:

1. Installs Docker via the official `get.docker.com` one-liner (no-op if already installed).
2. Builds the `claude-sandbox` image from the uploaded Dockerfile (first build downloads Ubuntu base + native installer; subsequent builds are cached).
3. Installs the wrapper at `~/.local/bin/sandbox/claude` and prepends that dir to PATH in `~/.bashrc` (idempotent).
4. Strips the bootstrap's `alias claude='claude --effort max'` line from `~/.bashrc`. The wrapper enforces `--effort max` already, so the alias would otherwise pass the flag twice on every invocation.

The script needs `sudo` for the Docker install + first build. The agent user has passwordless sudo from `/setup`, so this runs without prompting.

## Verify

After it finishes:

```
ssh agent@<host>
which claude        # should print ~/.local/bin/sandbox/claude
claude --version    # runs inside Docker; expect a few-second cold start
```

If `which claude` still points at the host binary, the PATH change hasn't taken effect — open a fresh shell or `source ~/.bashrc`.

If `docker` commands fail with "permission denied" inside the new shell, the user needs to fully log out + back in for the `docker` group membership added by the install script to take effect. Until then, `sudo` is required for `docker run` invocations.

## Caveats to surface in the report-back

- **Custom hooks / agents / skills / settings.json don't apply inside the sandbox.** Only `~/.claude/CLAUDE.md` (read-only) is mounted. Hooks specifically are kept off — a process inside the container could otherwise write to the host's hooks directory and execute code on the host on next invocation.
- **Sessions don't persist across container runs.** `~/.claude/projects/` (per-session JSONL state) is not mounted. Each `claude` invocation starts fresh; `claude --resume` won't see prior sessions.
- **CWD traps.** The wrapper refuses to mount `/` or `$HOME` as `/workspace` — `cd` into a specific repo before running `claude`.
- **Network is open.** Filesystem-only sandbox. If the user wants egress restriction (allowlist `api.anthropic.com` only), point them at iptables / docker network rules — out of scope for this command.
- **Cove integration.** If they use cove, `cove vps` works without modification: tmux panes resolve `claude` via the new PATH.

## Removing the sandbox

If the user wants to revert:

```
ssh agent@<host> bash -lc '
  rm -rf "$HOME/.local/bin/sandbox" "$HOME/claude-sandbox"
  sed -i "/claude-vps-sandbox-PATH/,+1d" "$HOME/.bashrc"
  if ! grep -q "^alias claude=.claude --effort max." "$HOME/.bashrc"; then
    printf "\n# Default Claude Code to maximum reasoning effort on the VPS.\nalias claude=\x27claude --effort max\x27\n" >> "$HOME/.bashrc"
  fi
  docker rmi claude-sandbox || sudo docker rmi claude-sandbox
'
```

`claude` resolves to the host binary again on next shell, with the bootstrap's `--effort max` alias restored. Docker itself is left installed; the user can `sudo apt remove docker-ce docker-ce-cli` if they want it gone.

## Status

This command is wired but has not yet been run end-to-end against a real VPS. Expect to debug at least one thing on first run — most likely the `docker` group membership timing or a CWD-mount edge case. File issues with full output if it breaks.
