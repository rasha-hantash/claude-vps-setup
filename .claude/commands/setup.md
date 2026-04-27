# /setup

Main wizard. Provisions a Hetzner VM, hardens it, installs Tailscale and Claude Code, and leaves the user with a box they can SSH into from their phone.

## Before you start

1. Check whether `./.setup-state.json` already exists. If it does, ask the user whether they want to reconfigure an existing VPS or start over — don't silently overwrite.
2. Check whether `hcloud` is on PATH. If not, use `AskUserQuestion` to ask whether to install via `brew install hcloud` (assume macOS unless `uname` says otherwise). On confirmation, run the install. If they decline, on a non-macOS system, or if Homebrew is missing, point at https://github.com/hetznercloud/cli/releases and stop. Never install silently — always confirm first since this CLI ends up on their PATH.
3. Check whether `tailscale` is on PATH. If not, follow the same `AskUserQuestion` pattern — offer `brew install tailscale` on macOS, otherwise direct them to https://tailscale.com/download. Note: Tailscale also requires the user to log in via the GUI app (one-time, browser-based) before `tailscale status` will return a hostname. Surface this as a follow-up step if the install succeeds.
4. SSH key check:
   a. Scan `~/.ssh/*.pub` for existing public keys. Filter to lines whose first whitespace-separated token is `ssh-ed25519`, `ssh-rsa`, or `ecdsa-sha2-*` (skip stray files that aren't actually keys).
   b. If one or more valid keys exist, present them via `AskUserQuestion`: "Use existing key, or generate a new one?". Default to the first ed25519 key if available; otherwise the first valid key. Capture the chosen `.pub` path — the corresponding private key is the same path without `.pub`. Don't generate a new key when a usable one already exists unless the user explicitly opts to.
   c. If none exist (or the user opts to generate fresh), ask via `AskUserQuestion` whether to run `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""` (no passphrase). Confirm explicitly — keypairs persist on disk.
   d. If they decline both options, stop with the manual `ssh-keygen` command.
5. macOS Remote Login (sshd) must be enabled so the VPS can SSH back into the laptop for `vps-sync-repo`. There is no programmatic toggle without Full Disk Access, so just instruct: "Open System Settings → General → Sharing → Remote Login and toggle it ON. Reply 'done' when enabled." Then verify post-hoc by attempting `ssh <laptop-user>@<tailscale-hostname> true` after bootstrap. If verification fails, surface the manual recovery steps in the report-back rather than blocking.

When asking via `AskUserQuestion`, batch the missing prereqs into a single question if there are several — "Install hcloud and tailscale via brew? [Y/n]" — rather than asking one at a time.

## Required secrets (env vars only — never via `AskUserQuestion`)

Two secrets are needed: `HCLOUD_TOKEN` (Hetzner API token, Read & Write scope) and `TS_AUTH_KEY` (Tailscale reusable auth key). Both **must** be set in the shell that started `claude`. Never prompt for these via `AskUserQuestion` — that widget renders pasted text in plaintext in the option list, leaking the secret into terminal scrollback and the session transcript.

Check both env vars before doing anything else (after the prereq checks above). If either is unset, print this exact block and stop:

> Two secrets need to live in your shell environment before `/setup` can run:
>
> ```bash
> # Hetzner API token — console.hetzner.cloud → your project → Security → API tokens → Generate (Read & Write)
> export HCLOUD_TOKEN=<paste-token>
>
> # Tailscale auth key — login.tailscale.com/admin/settings/keys → Generate (reusable, 90-day expiry is fine)
> export TS_AUTH_KEY=<paste-key>
> ```
>
> Run those in the same terminal you launched `claude` from, then re-run `/setup`. Env vars die when the shell closes — they aren't written to disk.

Do not offer to set them for the user. Do not paste the token into chat. Do not store them in `.setup-state.json`. The wizard reads them from its own environment when shelling out (`hcloud` and the bootstrap script).

## Collect inputs (use `AskUserQuestion`, one at a time)

Ask each of these as a separate `AskUserQuestion` call:

1. **VM type.** Multiple choice — pulled live from Hetzner. Pick the spec first; the location prompt that follows will only show regions where the chosen type can actually be provisioned. (Hetzner rolls out new types EU-first, so `cx23` is currently NBG-1 / HEL-1 only, while `cpx22` and `cx22` are available across all regions. Asking spec first avoids dead-end paths.)

   Pull the list (`hcloud` reads `HCLOUD_TOKEN` from env automatically):
   ```
   hcloud server-type list -o json | \
     jq -r '
       .[]
       | select(.deprecated == null)
       | {
           name,
           cores,
           memory,
           description,
           locations: [.prices[].location] | sort,
           price_eu_monthly: ([.prices[] | select(.location == "nbg1") | .price_monthly.gross] | first // "n/a")
         }
     '
   ```
   Present each type as: `<name> — <cores> vCPU / <memory> GB — <description> — available in <locations> — from €<price>/mo`. Default to the cheapest non-deprecated `cx*` (Intel/AMD shared, cost-optimized) type with ≥4 GB RAM. If none match, fall back to the cheapest available type.

2. **Region.** Multiple choice — only locations where the chosen type is available. Filter the same JSON:
   ```
   <previous output> | jq -r --arg type "<chosen-type>" '
     map(select(.name == $type))
     | first
     | .locations[]
   '
   ```
   Then enrich each code with city / country via:
   ```
   hcloud location list -o json | \
     jq -r '.[] | "\(.name)|\(.city)|\(.country)"'
   ```
   Present each as `<name> — <city>, <country>` (e.g., `nbg1 — Nuremberg, DE`). Default to whichever available location is geographically closest to the user's timezone if known; otherwise prompt without a default.

   If either query returns zero results, that's a bug — surface the raw API response and stop.
3. **VM name.** Freeform. Default `claude-box`.
4. **SSH public key path.** Freeform. Default `~/.ssh/id_ed25519.pub`. Verify the file exists before proceeding.
5. **Will you want Paper Desktop integration later?** Yes/no. (Just recorded in state for `/add-paper` — don't act on it here.)
6. **Will you want an HTTPS dev preview later?** Yes/no. (Same — recorded for `/add-https`.)

## Confirm

Before spending money, summarize the plan back to the user:

> I'm about to create a `<chosen-type>` VM named `<chosen-name>` in `<chosen-region>`, register your SSH key, and run the bootstrap script to install Tailscale and Claude Code. This will cost ~€<live-monthly-price>/mo starting now (Hetzner bills hourly, so a few hours of testing is well under €0.05). Continue?

Use the live monthly price from the server-type query in step 1 — don't hardcode a number.

Wait for explicit confirmation.

## Execute

1. Provision the VM (`HCLOUD_TOKEN` is inherited from the wizard's env — don't re-pass it on the command line):
   ```
   VM_NAME=<name> \
   VM_LOCATION=<region> \
   VM_TYPE=<type> \
   SSH_KEY_PATH=<path> \
   ./scripts/provision-hetzner.sh
   ```
   The script prints the VM's public IPv4 on the last line. Capture it.

2. Wait for SSH to come up. Poll `ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@<ip> true` every 10 seconds for up to 3 minutes.

3. Copy the bootstrap script, templates, and helper scripts to the VPS:
   ```
   scp scripts/bootstrap-vps.sh root@<ip>:/root/
   scp templates/tmux.conf root@<ip>:/root/tmux.conf
   scp templates/global-claude-md.md root@<ip>:/root/global-claude-md.md
   scp scripts/vps-clone.sh root@<ip>:/root/vps-clone
   scp scripts/vps-sync-repo.sh root@<ip>:/root/vps-sync-repo
   ```

4. Detect the laptop's Tailscale hostname and macOS username (so bootstrap can persist `LAPTOP_HOST=user@host` for `vps-sync-repo`):
   ```
   LAPTOP_HOSTNAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
   LAPTOP_USER=$(whoami)
   ```
   The user form is critical: SSH from the VPS defaults to the VPS-side username (`agent`), which doesn't exist on the laptop. Forwarding `LAPTOP_USER` makes the persisted `LAPTOP_HOST` connect as the right account. If `tailscale` isn't running on the laptop, leave `LAPTOP_HOSTNAME` empty — the helpers will still work once the user manually exports `LAPTOP_HOST=...` in their VPS shell.

5. Run bootstrap remotely (forward `TS_AUTH_KEY` from the wizard's env into the SSH session — don't echo it to chat). Capture the output so we can grep the agent's pubkey out of it:
   ```
   BOOTSTRAP_OUTPUT=$(ssh root@<ip> "TS_AUTH_KEY='$TS_AUTH_KEY' LAPTOP_HOSTNAME='<laptop-hostname>' LAPTOP_USER='<laptop-user>' bash /root/bootstrap-vps.sh" | tee /dev/tty)
   ```
   The single quotes around `'$TS_AUTH_KEY'` prevent the shell on the VPS from re-interpreting the value, and the surrounding double quotes let the local shell expand the variable. `tee /dev/tty` streams output to the user while still capturing it. If it fails, don't try to recover silently — show them the error and stop.

6. Extract the agent's SSH pubkey from the bootstrap output and append it to the laptop's `~/.ssh/authorized_keys` so the VPS can SSH back to the laptop for `vps-sync-repo`:
   ```
   AGENT_PUBKEY=$(echo "$BOOTSTRAP_OUTPUT" | sed -n '/AGENT_PUBKEY_BEGIN/,/AGENT_PUBKEY_END/p' | sed '1d;$d')
   ```
   If the line is missing, surface a warning and let the user paste it manually later. Otherwise, before appending, check whether the same key is already present (idempotent re-runs):
   ```
   if ! grep -qF "$AGENT_PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
     mkdir -p ~/.ssh && chmod 700 ~/.ssh
     touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
     echo "$AGENT_PUBKEY" >> ~/.ssh/authorized_keys
   fi
   ```
   No `AskUserQuestion` here — appending to your own `authorized_keys` from a wizard you ran locally is not a security boundary worth a prompt.

7. Fetch the VPS's Tailscale hostname:
   ```
   ssh root@<ip> "sudo -u agent tailscale status --json | jq -r '.Self.DNSName' | sed 's/\\.$//'"
   ```

8. Test Tailscale SSH from the laptop:
   ```
   ssh agent@<tailscale-hostname> true
   ```
   If this fails, the user probably isn't logged into Tailscale on their laptop — tell them to run `tailscale up` and retry.

9. Verify the reverse path (VPS → laptop) works for `vps-sync-repo`:
   ```
   ssh agent@<tailscale-hostname> "ssh -o ConnectTimeout=5 -o BatchMode=yes <laptop-user>@<laptop-hostname> true"
   ```
   If this fails, the most common cause is macOS Remote Login still off — surface the System Settings → General → Sharing → Remote Login instruction in the report-back. Don't block.

10. Offer to sync the user's personal `~/.claude/` config to the VPS. Use `AskUserQuestion` with two options (default Yes):
    > Sync your personal `~/.claude/` config (CLAUDE.md, hooks, agents, skills, commands, settings.json) to the VPS? Skip this if you want a clean global config on the box.

    If yes:
    ```
    rsync -av --info=progress2 \
      ~/.claude/CLAUDE.md \
      ~/.claude/hooks \
      ~/.claude/agents \
      ~/.claude/skills \
      ~/.claude/commands \
      ~/.claude/settings.json \
      agent@<tailscale-hostname>:~/.claude/
    ```
    Skip any path that doesn't exist on the laptop (rsync will already complain; just `2>/dev/null || true` per item if you want clean output, or run the command as-is and surface any missing-path warnings to the user).

    Caveats to mention if Yes was chosen:
    - Hooks or scripts referencing absolute laptop paths (`/Users/<name>/...`) won't resolve on the VPS — point this out so the user can patch them later.
    - `~/.claude/projects/` (per-session state) and `~/.claude/.credentials.json` (OAuth) are intentionally **not** synced. Credentials should be regenerated on the VPS via `claude` first-run; project state is meant to be machine-local.
    - `settings.local.json` is project-scoped, not global — also intentionally skipped.

## Persist state

Write `./.setup-state.json`:

```json
{
  "vpsPublicIp": "...",
  "vpsTailscaleHostname": "...",
  "vmName": "...",
  "vmLocation": "...",
  "sshUser": "agent",
  "paperRequested": true,
  "httpsRequested": false,
  "createdAt": "<iso timestamp>"
}
```

Do not persist the Hetzner API token or the Tailscale auth key. If the user wants them saved, they can put them in their shell profile or a secrets manager — not in this repo.

## Report back

Tell the user:

- VPS public IP (for reference; they shouldn't need it again)
- Tailscale hostname (the thing they'll SSH to)
- Exact SSH command to try from their laptop: `ssh agent@<tailscale-hostname>`
- Exact workflow for their phone: install Termius/Blink, create a host using the Tailscale hostname, user `agent`, same SSH key
- The two repo helpers installed on the VPS: `vps-clone <owner/repo>` (clone + sync gitignored `.claude/` files from laptop) and `vps-sync-repo` (re-sync after the fact). Note that `LAPTOP_HOST="<laptop-user>@<laptop-hostname>"` is already set in the agent's `.bashrc` if step 4 found it.
- If step 9 (reverse SSH verification) failed, paste this manual recovery: (1) on the laptop, open System Settings → General → Sharing → Remote Login and toggle it ON; (2) confirm the VPS's pubkey appears in `~/.ssh/authorized_keys` on the laptop (the wizard appended it in step 6); (3) test `ssh agent@<tailscale-hostname>` and inside that session `ssh <laptop-user>@<laptop-hostname> true`. The first time the VPS connects to the laptop, it'll prompt to accept the host key — answer yes once and it's persisted.
- `vps-sync-repo` rsyncs all gitignored `.claude/` content from the laptop, including `.claude/worktrees/`. If your worktree directory is heavy (`du -sh .claude/` to check), expect the first sync to take a while at home upload speeds. A future improvement will prune merged/clean worktrees before syncing.
- Claude Code on the VPS defaults to `--effort max` via a shell alias, since long-running remote sessions are the normal use case for this setup.
- The user must run `claude` once on the VPS to complete first-run OAuth. The CLI prints a login URL; the user pastes it into their laptop's browser, signs in, then pastes the auth code back into the SSH terminal. Credentials are saved to `~/.claude/.credentials.json`. Show the exact command: `ssh agent@<tailscale-hostname> -t claude` (the `-t` forces TTY allocation so the interactive prompt works).
- The user must also run `gh auth login` once on the VPS so `vps-clone <owner/repo>` can clone private repos. Same TTY pattern — show: `ssh agent@<tailscale-hostname> -t gh auth login`. Pick GitHub.com → HTTPS → device code flow (it prints an 8-char code; the user opens https://github.com/login/device on their laptop and pastes it).
- Next steps based on what they answered for Paper/HTTPS: suggest `/add-paper` or `/add-https`
