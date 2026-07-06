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

# NOTE: no --omit=optional here — Claude Code ships its platform-native engine
# as an optional dependency; omitting it installs a launcher that dies with
# "claude native binary not installed".
install_agent() {
  mkdir -p "$PREFIX"
  npm install --prefix "$PREFIX" "${AGENT_PACKAGE}@${AGENT_VERSION}"
}

if [[ -x "$bin_dir/$AGENT" ]]; then
  # Validate the cached install; a broken one (e.g. cached before a fix, or a
  # half-saved cache) gets one clean reinstall instead of failing the review.
  if "$bin_dir/$AGENT" --version >/dev/null 2>&1; then
    echo "$AGENT restored from cache."
  else
    echo "Cached $AGENT install is broken; reinstalling."
    rm -rf "$PREFIX"
    install_agent
  fi
else
  install_agent
fi

# Pre-warm. The Copilot CLI is a launcher that downloads its platform engine
# into its own cache directory on first run; invoking it here pulls the engine
# in while the cache step can still save it. For claude this just verifies the
# install. Best-effort: a failure here surfaces on the real run instead.
echo "$AGENT: $("$bin_dir/$AGENT" --version 2>/dev/null || echo '?')"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin_dir" >> "$GITHUB_PATH"
fi
