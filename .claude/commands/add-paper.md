# /add-paper

Bridge Paper Desktop (running on the user's laptop) to the VPS, so Claude Code on the VPS can talk to Paper's local MCP server.

## Before you start

1. Read `./.setup-state.json`. If it doesn't exist, tell the user to run `/setup` first and stop.
2. Confirm the VPS is reachable: `ssh agent@<tailscale-hostname> true`. If it fails, don't proceed — the Tailscale link must be healthy first.
3. Read `docs/known-unknowns.md` — specifically the items about Paper's bind address, Host header behavior, and plugin URL overrides. Several steps below have "if X then Y" forks that depend on what you observe.

## Verify Paper Desktop is running locally

Before anything else, the user needs Paper Desktop installed, running, and with a file open (the MCP only starts when a file is open). You can't install it for them — it's a GUI app.

Walk them:

1. Tell them to download Paper Desktop from https://paper.design/downloads if they haven't.
2. Tell them to open any Paper file.
3. Test locally: `curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:29979/mcp`. A 200, 400, or 405 all mean "the server is there." A connection refused means Paper isn't running or no file is open — tell the user and wait.

## Decide the bridge strategy

Run these probes on the VPS to determine which bridge strategy works:

```
ssh agent@<tailscale-hostname> "curl -sS -o /dev/null -w '%{http_code}\n' --max-time 3 http://<laptop-tailscale-ip>:29979/mcp || echo 'refused'"
```

- If you get a refused: Paper binds strictly to `127.0.0.1`. You must use Option A (SSH reverse tunnel).
- If you get a status code: Paper accepts non-loopback connections. Option B (direct over Tailscale) is possible but still consider Option A for simplicity.

Default to **Option A** unless the user has a specific reason not to.

## Option A — SSH reverse tunnel (default)

1. Run `./scripts/laptop-paper-tunnel.sh <tailscale-hostname>` on the laptop. The script:
   - Starts `autossh -N -R 29979:127.0.0.1:29979 agent@<tailscale-hostname>` in the background
   - Writes a launchd plist (macOS) or systemd user unit (Linux) so the tunnel comes up at login
2. Test from the VPS: `ssh agent@<tailscale-hostname> "curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:29979/mcp"`. Should return 200/400/405, not connection refused.
3. If the test fails, walk through `docs/known-unknowns.md` item 1 (bind address) and item 2 (Host header) before trying to debug further.

## Install the Paper plugin inside Claude Code on the VPS

The plugin install happens inside an interactive Claude Code session on the VPS, not from here. Give the user exactly this sequence to run:

```
ssh agent@<tailscale-hostname>
tmux new -s paper-setup
claude
```

Then inside Claude Code on the VPS:

```
/plugin marketplace add paper-design/agent-plugins
/plugin install paper-desktop@paper
```

Tell the user to try a test prompt like "list the frames in my current Paper file" and report back whether it worked.

## Update state

Add to `./.setup-state.json`:

```json
{
  "paperBridge": "autossh-reverse-tunnel",
  "paperBridgeSetupAt": "<iso timestamp>"
}
```

## Known unknowns to surface to the user

Before they rely on this, tell them (condensed version of `docs/known-unknowns.md`):

- Paper Desktop must be running with a file open, every session. The tunnel can't help if Paper isn't up.
- The laptop must be awake and online. If they close it, the VPS can't reach Paper.
- The plugin's URL is hardcoded to `127.0.0.1:29979`. If Paper ever changes the port, this bridge breaks until we update.
