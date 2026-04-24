# CLAUDE.md

This repo is an interactive installer. When invoked here via `claude`, your job is to drive a user through setting up Claude Code on a Hetzner VPS, reachable from their phone, with optional Paper Design MCP integration.

**You are running on the user's laptop.** The VPS does not exist yet. The scripts and commands in this repo provision and configure it.

## How this repo is organized

- `.claude/commands/` — slash commands the user invokes. Each command is a markdown runbook you follow.
  - `setup.md` — `/setup`, the main wizard. Run this first.
  - `add-paper.md` — `/add-paper`, bridge Paper Desktop to the VPS. Runs after `/setup`.
  - `add-https.md` — `/add-https`, add a Caddy + Let's Encrypt preview. Runs after `/setup`.
- `scripts/` — deterministic bash. You call these with arguments you've collected from the user.
  - `provision-hetzner.sh` — creates the VM via `hcloud`.
  - `bootstrap-vps.sh` — runs on the VPS: user setup, UFW, Tailscale, Node, Claude Code.
  - `laptop-paper-tunnel.sh` — starts the autossh reverse tunnel from laptop to VPS.
- `templates/` — files you copy into place (tmux config, Caddyfile, global CLAUDE.md for the VPS, launchd plist).
- `docs/known-unknowns.md` — conditional-logic list. Check this whenever a step has an "if X then Y else Z" shape.

## Rules for how you drive

1. **Ask one question at a time.** Use the `AskUserQuestion` tool. Don't dump a list of questions as free text — it makes the wizard feel un-interactive. Multiple-choice where possible (regions, yes/no), freeform only when truly freeform (API tokens, domain names).

2. **Commands ask, scripts execute.** The markdown commands handle user interaction and flow. Actual shell work happens in `scripts/*.sh`. Don't regenerate shell inline when a script already exists.

3. **State lives in `./.setup-state.json`.** After `/setup` completes, write the VPS IP, Tailscale hostname, SSH user, and any other values `/add-paper` or `/add-https` will need. Read it back at the start of every follow-up command so you don't re-ask.

4. **Confirm before anything irreversible.** Creating a VM costs money. Writing DNS records is visible. Opening port 443 exposes the box. Summarize what's about to happen and get an explicit "go" before running the step.

5. **Test each step before moving on.** If you just brought up Tailscale on the VPS, SSH in over Tailscale before installing anything else. The point of this tool is that each step is independently verifiable.

6. **When a step has an environmental fork** (does Paper's MCP accept this Host header? did DNS propagate?), go read `docs/known-unknowns.md` and test the condition rather than guessing.

7. **Don't skip prompts with `--dangerously-skip-permissions` during setup.** The VPS-side Claude Code install will ask about that itself later. For this installer running on the user's laptop, normal permission prompts are correct.

## What you don't do

- You don't run Paper Desktop install for the user. Paper Desktop is a GUI app; the user installs it by hand. You verify it's running by curl-ing `localhost:29979`.
- You don't generate a Hetzner API token for the user. They go to the console, create one, and paste it back. Walk them there by URL.
- You don't write production secrets to this box. This is a dev VPS. If the user asks you to store credentials with broader scope than the VPS itself, warn them.
