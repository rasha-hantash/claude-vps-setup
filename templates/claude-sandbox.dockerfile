# claude-sandbox — minimal Ubuntu image with Claude Code's native installer.
#
# The host wrapper (~/.local/bin/sandbox/claude) bind-mounts:
#   $(pwd)                       → /workspace                                   (rw)
#   ~/.claude/.credentials.json  → /root/.claude/.credentials.json              (ro)
#   ~/.claude/CLAUDE.md          → /root/.claude/CLAUDE.md                      (ro)
#
# Inside, claude runs with --dangerously-skip-permissions. The container is the
# safety boundary, not the LLM. Egress is intentionally not restricted; the
# isolation is filesystem-only (no SSH keys, no host hooks, no other repos).

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git tini \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://claude.ai/install.sh -o /tmp/install.sh \
    && bash /tmp/install.sh \
    && rm /tmp/install.sh

ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--"]
