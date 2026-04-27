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

## Why Hetzner

Hetzner Cloud is cheap (the recommended `cx23` is roughly €4.49/mo at the time of writing — billed *hourly*, so a few hours of testing is well under €0.05), German-headquartered with EU privacy defaults, and has straightforward CLI/API surface. The wizard pulls live pricing and availability from the API at runtime — no hardcoded specs to drift.

The default pick is the cheapest non-deprecated `cx*` (Intel/AMD shared) instance with ≥4 GB RAM. You can override interactively if you want more cores or RAM (`cx33`, `cpx32`, etc.). Hetzner ships new types EU-first, so if you want a US East / US West / Singapore region, the wizard automatically filters to instance types actually provisionable there.

## What it installs on the VPS

- **Claude Code** (native installer, auto-updates — no Node toolchain required)
- **Tailscale** (`--ssh` enabled; SSH is *only* reachable over the tailnet, not the public internet)
- **GitHub CLI** (`gh`) so the included `vps-clone <owner/repo>` helper works for private repos
- **tmux**, **zsh**, **jq**, plus the helpers `vps-clone` and `vps-sync-repo`
- **UFW firewall** (deny-all incoming except Tailscale; SSH is closed to the public internet)
- A non-root user `agent` with passwordless `sudo`, an SSH keypair (so the VPS can rsync gitignored `.claude/` files back from your laptop), and a `claude --effort max` shell alias

## Prerequisites on your laptop

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and logged in
- A Hetzner Cloud account with an API token (Read & Write scope — instructions in step 1 below)
- A Tailscale account (free tier is fine), the [Tailscale macOS/Windows app](https://tailscale.com/download), and the daemon actually running before you start
- An SSH keypair at `~/.ssh/id_ed25519.pub` (or another path you'll provide; the wizard offers to generate one if you don't have any)
- **macOS Remote Login enabled**: System Settings → General → Sharing → Remote Login → ON. This is what lets the VPS rsync `.claude/` content back from your laptop. Off by default.
- For the Paper bridge: Paper Desktop installed locally

The `hcloud` and `tailscale` CLIs are installed by the script if missing.

## Quick start

The wizard reads two secrets from your shell environment instead of prompting for them — this avoids leaking tokens into terminal scrollback or the session transcript. Set them before launching `claude`:

```bash
# Hetzner API token
#   console.hetzner.cloud → your project → Security → API tokens → Generate (Read & Write)
export HCLOUD_TOKEN=<paste-token>

# Tailscale auth key (make it reusable, 90-day expiry is fine)
#   login.tailscale.com/admin/settings/keys → Generate
export TS_AUTH_KEY=<paste-key>

git clone <this-repo>
cd claude-vps-setup
claude
```

Inside Claude Code:

```
/setup
```

> **Note:** the slash command is loaded from `.claude/commands/setup.md` in this repo. If you see `Unknown command: /setup`, you launched `claude` from a different directory — `cd` into the cloned `claude-vps-setup` first.

Follow the prompts. When it's done you'll have a VPS reachable from your phone over Tailscale with Claude Code ready to use.

Two manual one-time auth steps remain on the VPS itself (no automation can skip these without forwarding tokens you don't want forwarded):

```bash
ssh agent@<tailscale-hostname> -t claude          # Claude Code OAuth
ssh agent@<tailscale-hostname> -t gh auth login   # GitHub auth (HTTPS or device flow)
```

The wizard also offers (opt-in, default Yes) to rsync your personal `~/.claude/` config — `CLAUDE.md`, `hooks/`, `agents/`, `skills/`, `commands/`, `settings.json` — from your laptop to the VPS so Claude Code there boots with the same global setup you have locally. `~/.claude/projects/` (per-session state) and `~/.claude/.credentials.json` (OAuth) are intentionally not synced; credentials regenerate on the VPS during the `claude` first-run above. If hooks or scripts in your config reference absolute laptop paths (e.g. `/Users/yourname/...`), they won't resolve on the VPS — patch those after sync.

Follow-up commands:

- `/add-paper` — bridge Paper Desktop's MCP server from your laptop to the VPS
- `/add-chrome` — bridge `claude-in-chrome` (browser automation MCP) from your laptop to the VPS, so VPS Claude has the same browser tools you'd have locally
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

v0. Baseline setup runs end-to-end against a real Hetzner account and produces a working VPS reachable over Tailscale with `vps-clone` + `vps-sync-repo` functional after the auth steps above.

Known sharp edges:

- **First-run rsync of `.claude/worktrees/` can be heavy.** The helper sends every gitignored file under `.claude/` from the matching repo on your laptop, which includes worktree directories with their own `node_modules`. Multi-GB syncs take 5–30 min on home upload bandwidth. `du -sh .claude/` on the laptop tells you the payload before you commit. A future improvement will prune merged + clean worktrees before sync.
- **`/add-paper`** has known unknowns documented in `docs/known-unknowns.md` — read it before running.
- **`/add-https`** is wired but has not been run end-to-end against a real VPS. Expect to debug at least one thing on first run.
