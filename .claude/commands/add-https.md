# /add-https

Add a Caddy reverse proxy with auto-issued Let's Encrypt cert, so a dev server running on the VPS is reachable at `https://<domain>` from the user's phone.

## Before you start

1. Read `./.setup-state.json`. If missing, tell the user to run `/setup` first.
2. Confirm the VPS is reachable over Tailscale.
3. Remind the user this step opens port 443 to the public internet. That's the point, but it's worth saying out loud.

## Collect inputs

Ask (one at a time, `AskUserQuestion`):

1. **Domain.** Freeform. Must be a domain they control — `dev.something-i-own.com`.
2. **Local port.** The port the dev server listens on inside the VPS. Default `3000`.

## Wait for DNS

1. Get the VPS's public IPv4 from `./.setup-state.json`.
2. Tell the user:
   > Create an **A record** for `<domain>` pointing to `<public-ip>`, TTL 300. Reply "done" when it's saved.
3. After they say done, poll DNS: `dig +short <domain> A` until it returns the expected IP or 3 minutes elapse. Don't proceed before this succeeds — Caddy will fail the ACME challenge and you'll spend 20 minutes debugging a DNS cache.

## Configure the VPS

1. Open port 443 in UFW (SSH over Tailscale; public port 443 for Caddy):
   ```
   ssh agent@<tailscale-hostname> "sudo ufw allow 443/tcp"
   ```
2. Install Caddy if not present:
   ```
   ssh agent@<tailscale-hostname> "which caddy || sudo apt install -y caddy"
   ```
3. Template the Caddyfile from `templates/Caddyfile`, substituting `{{DOMAIN}}` and `{{PORT}}`:
   ```
   sed -e "s|{{DOMAIN}}|<domain>|g" -e "s|{{PORT}}|<port>|g" templates/Caddyfile > /tmp/Caddyfile
   scp /tmp/Caddyfile agent@<tailscale-hostname>:/tmp/Caddyfile
   ssh agent@<tailscale-hostname> "sudo mv /tmp/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy"
   ```

## Verify

From the laptop:

```
curl -sS -o /dev/null -w "%{http_code}\n" https://<domain>
```

Expect a 502 (Caddy up, no dev server running yet) or 200 (if they already have a server on that port). A 5xx other than 502 or a TLS error means Caddy didn't issue — check `ssh agent@<hostname> "sudo journalctl -u caddy -n 100"`.

## Update state

Add to `./.setup-state.json`:

```json
{
  "httpsDomain": "...",
  "httpsPort": 3000,
  "httpsSetupAt": "<iso timestamp>"
}
```

## Report back

- The URL (`https://<domain>`)
- How to test: start any dev server on the VPS bound to the port they chose (e.g., `npm run dev`), then open the URL on their phone
- If they want to change the port later, edit `/etc/caddy/Caddyfile` on the VPS and `sudo systemctl reload caddy`
