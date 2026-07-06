#!/usr/bin/env bash
# Install the agent CLI (Claude Code or Copilot CLI) from npm into a dedicated
# prefix that the action caches keyed on the resolved version. A cache hit
# restores the installed tree, so npm never runs.
set -euo pipefail

: "${AGENT:?AGENT is required}"
: "${AGENT_PACKAGE:?AGENT_PACKAGE is required}"
: "${AGENT_VERSION:?AGENT_VERSION is required}"
: "${PREFIX:?PREFIX is required}"

bin_dir="$PREFIX/node_modules/.bin"
if [[ -x "$bin_dir/$AGENT" ]]; then
  echo "$AGENT restored from cache."
else
  mkdir -p "$PREFIX"
  # --omit=optional skips optional native deps (e.g. fsevents, macOS-only via
  # chokidar, whose node-gyp build fails on Linux runners).
  npm install --prefix "$PREFIX" --omit=optional "${AGENT_PACKAGE}@${AGENT_VERSION}"
fi

# Pre-warm. The Copilot CLI is a launcher that downloads its platform engine
# into its own cache directory on first run; invoking it here pulls the engine
# in while the cache step can still save it. For claude this just verifies the
# install. Best-effort: a failure here surfaces on the real run instead.
echo "$AGENT: $("$bin_dir/$AGENT" --version 2>/dev/null || echo '?')"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin_dir" >> "$GITHUB_PATH"
fi
