# Known unknowns

Conditional logic and unverified assumptions that the commands fork on. Read this when a step has an "if X then Y else Z" shape, and update it as we learn things.

## 1. Paper Desktop's MCP bind address

**Unknown**: Whether Paper Desktop binds its MCP server strictly to `127.0.0.1` or to `0.0.0.0`.

**Why it matters**: Determines whether Option B (direct over Tailscale to laptop's port 29979) is viable, or whether Option A (SSH reverse tunnel) is the only choice.

**How to test**: From the VPS, after Paper is running on the laptop:
```
curl -v --max-time 3 http://<laptop-tailscale-ip>:29979/mcp
```
- "Connection refused" → loopback-only. Use Option A.
- HTTP response → reachable. Either option works.

**Default behavior**: Assume loopback-only. Use Option A.

## 2. Paper Desktop's Host header policy

**Unknown**: Whether Paper's MCP server validates the `Host:` request header (rejecting non-localhost hosts as anti-CSRF).

**Why it matters**: Even if Paper binds `0.0.0.0`, it might still reject requests where `Host: <laptop-tailscale-ip>:29979` instead of `Host: 127.0.0.1:29979`. SSH reverse tunnel preserves `localhost` in the Host header; Tailscale Serve does not.

**How to test**:
```
curl -v -H "Host: 127.0.0.1:29979" http://<laptop-tailscale-ip>:29979/mcp
curl -v http://<laptop-tailscale-ip>:29979/mcp
```
Compare the two responses.

**Default behavior**: Use Option A regardless. It avoids this question entirely.

## 3. Paper plugin URL configurability

**Unknown**: Whether the `paper-desktop@paper` Claude Code plugin lets you override the default `http://127.0.0.1:29979/mcp` URL.

**Why it matters**: If overridable, Option B becomes simpler (just point at the laptop's Tailscale IP). If hardcoded, Option A is required.

**How to check**: After running `/plugin install paper-desktop@paper` on the VPS, inspect `~/.claude/` for the resulting MCP server config. Look for a URL field; check whether the plugin docs mention an env var or config knob.

**Default behavior**: Assume hardcoded. Option A handles both cases.

## 4. Laptop availability constraint

**Unknown**: Whether the user's laptop will reliably be on, awake, and on Tailscale during VPS sessions.

**Why it matters**: Every Paper-involving Claude session on the VPS requires the tunnel up, which requires laptop awake + Paper Desktop running + file open. If the laptop sleeps, the tunnel breaks.

**How to test**: Ask the user. There's no automated check.

**Default behavior**: Tell the user this constraint exists in `/add-paper`'s closing summary. Don't try to engineer around it.

## 5. DNS propagation timing for `/add-https`

**Unknown**: How long the user's DNS provider takes to propagate the A record before Caddy can complete the ACME challenge.

**Why it matters**: Caddy with auto-TLS will try to issue immediately. If DNS hasn't propagated, the challenge fails and Caddy backs off, sometimes for tens of minutes.

**How to test**: `dig +short <domain> A` from the laptop, comparing against the VPS's public IP. Poll until match.

**Default behavior**: `/add-https` polls for up to 3 minutes before letting Caddy try. Tell the user to wait if it's longer.

## 6. CX22 memory ceiling for large repos

**Unknown**: Whether 4 GB RAM is enough for the user's specific repos (Claude Code + a TypeScript LSP + a Next.js dev server can all be hungry).

**Why it matters**: OOM kills are a frustrating failure mode that doesn't surface a clear error.

**How to test**: After running for a few days, `ssh agent@<host> "dmesg -T | grep -i oom"`.

**Default behavior**: Start on CX22. If OOM appears, recommend resizing to CX32 in the Hetzner console (Hetzner allows resize without rebuild).

## 7. Hetzner API token scope and lifetime

**Unknown**: How long the user's Hetzner API token will remain valid, and whether they'll keep it in their shell profile or paste it fresh each time.

**Why it matters**: `/setup` can't re-run silently if the token is stale. Doesn't affect day-to-day use of the VPS.

**Default behavior**: Don't persist the token. If `/setup` fails with a 401 from `hcloud`, tell the user to regenerate.
