# /add-chrome

Bridge `claude-in-chrome` (running on the user's laptop with a real Chrome browser) to the VPS, so Claude Code on the VPS has the same browser-automation tools (`navigate`, `find`, `gif_creator`, `read_console_messages`, etc.) it would have if it were running locally. The agent on the VPS should not have to reason about whether to defer browser tasks to a local session — it gets the full toolset.

> **Status: untested.** Architecturally identical to `/add-paper`, but `claude-in-chrome`'s transport (HTTP vs. Chrome native-messaging stdio) hasn't been verified end-to-end. Treat as a starting point — the first run will surface which branch below applies.

## Before you start

1. Read `./.setup-state.json`. If missing, run `/setup` first.
2. Confirm the VPS is reachable: `ssh agent@<tailscale-hostname> true`.
3. Confirm the user has Chrome installed locally with the Claude in Chrome extension (`https://claude.ai/chrome` is the canonical install path — surface this if they haven't).

## Determine the transport (do this first)

`claude-in-chrome` is implemented as an MCP server. The bridge strategy depends on its transport:

- **HTTP/WebSocket on a localhost port** → autossh reverse tunnel (Option A — same as `/add-paper`).
- **stdio + Chrome Native Messaging** → reverse tunnel can't carry it (native messaging requires the connector process and Chrome to be on the same machine). Need Option B (HTTP shim).

Probe on the laptop to find out:

```bash
# 1. List running processes that look like the Claude Chrome connector
pgrep -af "claude.*chrome"

# 2. Check whether anything is listening on localhost ports in the typical MCP range
lsof -nP -iTCP -sTCP:LISTEN | grep -i -E "claude|chrome"

# 3. Inspect the user's Claude Code MCP config
cat ~/.claude/.claude.json 2>/dev/null | jq '.mcpServers["claude-in-chrome"] // empty'
cat ~/.claude/mcp.json     2>/dev/null | jq '.mcpServers["claude-in-chrome"] // empty'
```

- If `.claude.json` shows `claude-in-chrome` with a `url` field → **HTTP**. Capture the port. Proceed to Option A.
- If `mcp.json` shows it with a `command` field (stdio) → **stdio**. Proceed to Option B.
- If neither shows anything, the user hasn't installed `claude-in-chrome` yet — surface install instructions and stop.

## Option A — SSH reverse tunnel (HTTP transport)

Mirrors `/add-paper`. Forwards laptop `127.0.0.1:<port>` to VPS `127.0.0.1:<port>` via autossh + launchd/systemd.

1. On the laptop, run:
   ```
   ./scripts/laptop-chrome-tunnel.sh <vps-tailscale-hostname> <chrome-mcp-port>
   ```
   The script:
   - Verifies Chrome MCP responds locally (`curl http://127.0.0.1:<port>/...`)
   - Generates a launchd plist (macOS) or systemd user unit (Linux) from `templates/autossh-chrome.plist`
   - Loads the unit so the tunnel comes up at every login
2. Test from the VPS:
   ```
   ssh agent@<tailscale-hostname> "curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 http://127.0.0.1:<chrome-mcp-port>/"
   ```
   Should return a status code (not "connection refused"). If refused, the tunnel didn't come up — check `~/Library/Logs/claude-vps-chrome-tunnel.err.log` on the laptop.
3. Add the MCP server to the VPS's Claude config so VPS Claude knows where to reach Chrome:
   ```
   ssh agent@<tailscale-hostname> "claude mcp add --transport http claude-in-chrome http://127.0.0.1:<chrome-mcp-port>/"
   ```
   (Or edit `~/.claude/.claude.json` directly if `claude mcp add` isn't available in the installed version.)

## Option B — HTTP shim (stdio + native messaging transport)

If `claude-in-chrome` runs as a stdio MCP using Chrome native messaging, a reverse tunnel can't carry it — native messaging is process-local. The workaround is to wrap the stdio MCP in an HTTP server on the laptop, then tunnel the HTTP layer.

1. On the laptop, write a small adapter (one of):
   - `mcp-proxy --transport http --port <port> -- <stdio-command>` (if `mcp-proxy` is available)
   - A 30-line Node/Python HTTP server that spawns the stdio MCP and proxies JSON-RPC over HTTP
2. Run the adapter under launchd/systemd so it survives logins.
3. From there, treat it exactly like Option A: reverse-tunnel the adapter's HTTP port and add the MCP to VPS Claude.

This option is sketched, not implemented. Surface it as a follow-up if the user lands on the stdio branch.

## Verify

From the VPS:

```
ssh agent@<tailscale-hostname> -t claude
```

Inside Claude Code on the VPS:

```
/mcp        # claude-in-chrome should appear
```

Then ask Claude to call any browser tool (e.g., "open a new tab to example.com and tell me the page title"). If it works, you're done.

## Update state

Add to `./.setup-state.json`:

```json
{
  "chromeBridge": "autossh-reverse-tunnel",
  "chromePort": <port>,
  "chromeBridgeSetupAt": "<iso timestamp>"
}
```

## Known limitations

Tell the user:

- The laptop must be awake, online, with Chrome running and the extension installed. If the laptop sleeps, the tunnel dies and so do the browser tools on the VPS.
- Every browser tool call on the VPS is a roundtrip VPS → Tailscale → laptop → Chrome → back. Expect 100-300 ms added per call. Multi-step UI flows (10 clicks) feel slow but work.
- If you ever close the lid mid-task, `autossh` reconnects automatically when the laptop wakes — the tunnel survives sleep cycles.
- For workflows that need *Chrome extensions other than `claude-in-chrome`* (e.g., 1Password, dev tools), they only run on the laptop's Chrome. The VPS isn't running its own browser.
