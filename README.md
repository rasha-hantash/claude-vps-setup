# claude-vps-setup

An interactive installer that spins up a Hetzner VPS, installs Claude Code on it, hardens access via Tailscale, and optionally wires up Paper Design's MCP server so Claude Code on the VPS can read and write your local Paper files.

The installer is driven by Claude Code itself — you run `claude` in this repo and type `/setup`. Claude asks one question at a time (like `create-next-app`), runs the deterministic scripts, and walks you through the decision points that need judgment.

## What it builds

```
  [phone] ──SSH over Tailscale──► [Hetzner VPS]  ──reverse tunnel──► [your laptop]
                                   ├─ Claude Code                    └─ Paper Desktop
                                   ├─ tmux sessions                     (MCP @ :29979)
                                   ├─ git worktrees
                                   └─ Caddy (optional HTTPS preview)
```

## Prerequisites on your laptop

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and logged in
- A Hetzner Cloud account with an API token (the `/setup` command walks you to the console)
- A Tailscale account (free tier is fine)
- An SSH keypair at `~/.ssh/id_ed25519.pub` (or another path you'll provide)
- For the Paper bridge: Paper Desktop installed locally

The `hcloud` and `tailscale` CLIs are installed by the script if missing.

## Quick start

```bash
git clone <this-repo>
cd claude-vps-setup
claude
```

Inside Claude Code:

```
/setup
```

Follow the prompts. When it's done you'll have a VPS reachable from your phone over Tailscale with Claude Code ready to use.

Follow-up commands:

- `/add-paper` — bridge Paper Desktop's MCP server from your laptop to the VPS
- `/add-https` — add a Caddy + Let's Encrypt preview at `https://your.domain` for any dev server on the VPS

## Running it without the agent

Every `.claude/commands/*.md` file is readable markdown. If you'd rather not have Claude Code drive, open `.claude/commands/setup.md` and execute the steps manually — the scripts in `scripts/` are the same ones the command calls.

## How much does the wizard save vs. doing it manually?

| Phase | Manual (from blog post) | Automated (`/setup`) | Saved |
|---|---|---|---|
| Provision Hetzner VM (console clicks, picking image/region/key) | 8–12 min | ~90 sec (one `AskUserQuestion` per field, then API call) | ~10 min |
| Bootstrap (user, SSH harden, UFW, Tailscale, Node, Claude Code) | 25–40 min, ~15 commands, easy to typo | 3–5 min, single script | ~30 min |
| Tmux + global CLAUDE.md + mobile ergonomics | 10–15 min (writing config) | 0 — already templated | ~12 min |
| Paper bridge (autossh + persistent unit) | 30–60 min (most people have never written a launchd plist) | 2 min (`/add-paper`) | ~45 min |
| HTTPS preview (UFW, Caddy, DNS coordination) | 15–20 min | 3–4 min (`/add-https`) | ~15 min |
| **Total first run** | **~90 min – 2.5 hours** | **~10–15 min of clock time, ~3 min of attention** | **~80–130 min** |

The bigger win isn't the first run — it's the second one. New laptop, second VPS, helping a friend, reproducing the setup six months from now: manual is another 90 minutes, automated is another 10. That ratio is where this earns its keep.

A few minutes that no automation can compress: generating the Hetzner API token (browser click), generating the Tailscale auth key (browser click), and installing Tailscale on the laptop (GUI app). Plan on ~3–4 minutes of pure human time even in the automated flow.

## Status

v0. Works end-to-end for the baseline setup. The Paper bridge has known unknowns documented in `docs/known-unknowns.md` that you'll want to read before running `/add-paper`.
