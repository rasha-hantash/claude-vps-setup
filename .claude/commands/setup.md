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

When asking via `AskUserQuestion`, batch the missing prereqs into a single question if there are several — "Install hcloud and tailscale via brew? [Y/n]" — rather than asking one at a time.

## Collect inputs (use `AskUserQuestion`, one at a time)

Ask each of these as a separate `AskUserQuestion` call:

1. **Hetzner API token.** Freeform. Before asking, paste this in chat so the user can see what to do:
   > Go to https://console.hetzner.cloud/ → your project → Security → API tokens → Generate API token. Give it **Read & Write** scope. Copy the token and paste it below. The token is only shown once.
2. **Region.** Multiple choice: `nbg1` (Nuremberg 🇩🇪), `fsn1` (Falkenstein 🇩🇪), `hel1` (Helsinki 🇫🇮), `ash` (Ashburn 🇺🇸), `hil` (Hillsboro 🇺🇸), `sin` (Singapore 🇸🇬). Default: whichever is geographically closest — you can guess from the user's timezone if you have it, otherwise ask.
3. **VM type.** Multiple choice: `cx23` (2 vCPU / 4 GB — recommended), `cx33` (4 vCPU / 8 GB — if repos are big), `cpx22` (AMD shared vCPU alternative). Default `cx23`. (Pricing changes — check `hcloud server-type describe <type>` or hetzner.com/cloud for current monthly cost before confirming.)
4. **VM name.** Freeform. Default `claude-box`.
5. **SSH public key path.** Freeform. Default `~/.ssh/id_ed25519.pub`. Verify the file exists before proceeding.
6. **Tailscale auth key.** Freeform. Before asking, paste:
   > Go to https://login.tailscale.com/admin/settings/keys → Generate auth key. Make it **reusable** and set an expiry you're comfortable with (90 days is fine). Copy the `tskey-auth-...` value and paste it below.
7. **Will you want Paper Desktop integration later?** Yes/no. (Just recorded in state for `/add-paper` — don't act on it here.)
8. **Will you want an HTTPS dev preview later?** Yes/no. (Same — recorded for `/add-https`.)

## Confirm

Before spending money, summarize the plan back to the user:

> I'm about to create a `cx23` VM named `claude-box` in `nbg1`, register your SSH key, and run the bootstrap script to install Tailscale and Claude Code. This will cost ~€4.49/mo starting now (Hetzner bills hourly, so a few hours of testing is well under €0.05). Continue?

Wait for explicit confirmation.

## Execute

1. Provision the VM:
   ```
   HCLOUD_TOKEN=<token> \
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

4. Detect the laptop's Tailscale hostname (so the bootstrap can persist it for the helpers):
   ```
   LAPTOP_HOSTNAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
   ```
   If `tailscale` isn't running on the laptop, leave `LAPTOP_HOSTNAME` empty — the helpers will still work once the user manually exports `LAPTOP_HOST=...` in their VPS shell.

5. Run bootstrap remotely:
   ```
   ssh root@<ip> "TS_AUTH_KEY=<key> LAPTOP_HOSTNAME=<laptop-hostname> bash /root/bootstrap-vps.sh"
   ```
   Stream the output so the user can see progress. If it fails, don't try to recover silently — show them the error and stop.

6. Fetch the VPS's Tailscale hostname:
   ```
   ssh root@<ip> "sudo -u agent tailscale status --json | jq -r '.Self.DNSName' | sed 's/\\.$//'"
   ```

7. Test Tailscale SSH from the laptop:
   ```
   ssh agent@<tailscale-hostname> true
   ```
   If this fails, the user probably isn't logged into Tailscale on their laptop — tell them to run `tailscale up` and retry.

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
- The two repo helpers installed on the VPS: `vps-clone <owner/repo>` (clone + sync gitignored `.claude/` files from laptop) and `vps-sync-repo` (re-sync after the fact). Note that `LAPTOP_HOST` is already set in the agent's `.bashrc` if step 4 found it.
- Claude Code on the VPS defaults to `--effort max` via a shell alias, since long-running remote sessions are the normal use case for this setup.
- The user must run `claude` once on the VPS to complete first-run OAuth. The CLI prints a login URL; the user pastes it into their laptop's browser, signs in, then pastes the auth code back into the SSH terminal. Credentials are saved to `~/.claude/.credentials.json`. Show the exact command: `ssh agent@<tailscale-hostname> -t claude` (the `-t` forces TTY allocation so the interactive prompt works).
- Next steps based on what they answered for Paper/HTTPS: suggest `/add-paper` or `/add-https`
