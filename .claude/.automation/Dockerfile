# Repo OS Runner — Docker container template.
# Decision 0017 — Operator Automation Layer.
#
# BUILD:
#   docker build -t repo-os-runner .claude/.automation/
#
# RUN:
#   docker run -d \
#     -v /path/to/your/repo:/workspace \
#     -v /path/to/claude-credentials:/credentials:ro \
#     -e CLAUDE_CONFIG_DIR=/credentials \
#     --name repo-os-runner \
#     repo-os-runner
#
# NOTES:
#   - /workspace: mount your repo root here (read-write)
#   - /credentials: mount directory containing Claude API credentials (read-only)
#   - Adapt CLAUDE_CONFIG_DIR to match your credential layout
#   - The runner idles on poll_interval when no queue entries are pending
#   - Stop gracefully: docker stop repo-os-runner (sends SIGTERM)
#   - Emergency stop: create HALT file in .claude/.automation/

FROM ubuntu:22.04

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    curl \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Claude CLI — install via official method (adapt as needed)
# The operator should replace this with their preferred installation method.
# Example: COPY claude /usr/local/bin/claude
RUN echo "TODO: Install claude CLI — see https://docs.anthropic.com" && \
    echo "Replace this RUN block with your installation method"

# Working directory is the mounted repo
WORKDIR /workspace

# Health check: verify the .health file exists and daemon PID is running.
# NOTE: Does not check file freshness — poll_interval is configurable in
# config.yaml (default 60s) and a static freshness window would break when
# operators increase it. The health_is_alive() function in lib/health-check.sh
# provides the authoritative liveness check.
HEALTHCHECK --interval=120s --timeout=5s --retries=3 \
  CMD test -f /workspace/.claude/.automation/.health && \
      pid=$(grep '^pid:' /workspace/.claude/.automation/.health 2>/dev/null | sed 's/.*: *//') && \
      test -n "$pid" && kill -0 "$pid" 2>/dev/null

# Entry point: daemon mode
ENTRYPOINT ["/bin/bash", ".claude/.automation/runner.sh", "--daemon"]
