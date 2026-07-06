#!/usr/bin/env bash
# Toolchain scripts: detect-node.sh (use the workflow's node when sufficient),
# resolve-versions.sh (release/npm version resolution for cache keys),
# install-appmap.sh and install-agent.sh (cache-hit skips the download/install).
# gh, npm, and curl are mocked; node is faked per-case with stub binaries.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SUITE_DIR/.." && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assert.sh"

echo "== toolchain install scripts =="

if ! command -v jq >/dev/null 2>&1; then
  echo "  (skipped: jq not installed)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PATH="$TEST_DIR/mocks:$PATH"
export GITHUB_OUTPUT="$TMP/gh_out"
export GITHUB_PATH="$TMP/gh_path"
export MOCK_NPM_LOG="$TMP/npm.log"
export MOCK_CURL_LOG="$TMP/curl.log"

reset() { : > "$GITHUB_OUTPUT"; : > "$GITHUB_PATH"; : > "$MOCK_NPM_LOG"; : > "$MOCK_CURL_LOG"; }

fake_node() { # <dir> <version, e.g. v20.0.0>
  mkdir -p "$1"
  printf '#!/bin/sh\necho %s\n' "$2" > "$1/node"
  chmod +x "$1/node"
}

# --- detect-node: sufficient node on PATH -> use it ---
reset
fake_node "$TMP/node22" v22.5.1
PATH="$TMP/node22:$PATH" NODE_MIN=22 \
  assert_ok "detect-node with node 22" bash "$ROOT/scripts/detect-node.sh"
out="$(cat "$GITHUB_OUTPUT")"
assert_contains "$out" "need-node=false" "workflow's node 22 is used as-is"
assert_contains "$out" "node-major=22" "node-major reports the existing major"

# --- detect-node: node too old -> install ---
reset
fake_node "$TMP/node20" v20.0.0
PATH="$TMP/node20:$PATH" NODE_MIN=22 \
  assert_ok "detect-node with node 20" bash "$ROOT/scripts/detect-node.sh"
out="$(cat "$GITHUB_OUTPUT")"
assert_contains "$out" "need-node=true" "node 20 is below the floor"
assert_contains "$out" "node-major=22" "node-major reports the version to install"

# --- detect-node: override the floor down -> old node accepted ---
reset
PATH="$TMP/node20:$PATH" NODE_MIN=20 \
  assert_ok "detect-node with floor overridden to 20" bash "$ROOT/scripts/detect-node.sh"
assert_contains "$(cat "$GITHUB_OUTPUT")" "need-node=false" "override accepts node 20"

# --- resolve-versions: latest release via gh; agent version via npm ---
# (APPMAP_IGNORE_PREINSTALLED: the dev machine may have a real appmap on PATH.)
reset
AGENT=claude GITHUB_TOKEN=x APPMAP_CLI_VERSION="" APPMAP_IGNORE_PREINSTALLED=true \
  assert_ok "resolve-versions (latest)" bash "$ROOT/scripts/resolve-versions.sh"
out="$(cat "$GITHUB_OUTPUT")"
assert_contains "$out" "appmap-version=9.9.9" "newest @appland/appmap release found"
assert_contains "$out" "appmap-url=https://github.com/getappmap/appmap-js/releases/download/%40appland%2Fappmap-v9.9.9/appmap-" "download URL uses the encoded release tag"
assert_contains "$out" "agent-package=@anthropic-ai/claude-code" "claude maps to its npm package"
assert_contains "$out" "agent-version=9.9.9" "agent version resolved via npm view"
assert_contains "$out" "appmap-preinstalled=false" "no preinstalled appmap detected"

# --- resolve-versions: pinned version -> no release listing needed ---
reset
AGENT=copilot APPMAP_CLI_VERSION=1.2.3 \
  assert_ok "resolve-versions (pinned)" bash "$ROOT/scripts/resolve-versions.sh"
out="$(cat "$GITHUB_OUTPUT")"
assert_contains "$out" "appmap-version=1.2.3" "pinned version used verbatim"
assert_contains "$out" "agent-package=@github/copilot" "copilot maps to its npm package"

# --- resolve-versions: preinstalled appmap wins ---
reset
mkdir -p "$TMP/preinstalled"
printf '#!/bin/sh\necho appmap 0.0.1\n' > "$TMP/preinstalled/appmap"
chmod +x "$TMP/preinstalled/appmap"
PATH="$TMP/preinstalled:$PATH" AGENT=claude \
  assert_ok "resolve-versions (preinstalled)" bash "$ROOT/scripts/resolve-versions.sh"
out="$(cat "$GITHUB_OUTPUT")"
assert_contains "$out" "appmap-preinstalled=true" "preinstalled appmap detected"
assert_contains "$out" $'appmap-url=\n' "no download URL when preinstalled"

# --- resolve-versions: unknown agent fails ---
reset
AGENT=bogus assert_fail "unknown agent fails" bash "$ROOT/scripts/resolve-versions.sh"

# --- install-appmap: fresh -> download; cached -> no download ---
reset
DEST="$TMP/appmap-bin" APPMAP_URL="https://example.test/appmap-x" \
  assert_ok "install-appmap (fresh)" bash "$ROOT/scripts/install-appmap.sh"
assert_file "$TMP/appmap-bin/appmap" "binary installed"
assert_contains "$(cat "$MOCK_CURL_LOG")" "https://example.test/appmap-x" "downloaded from the release URL"
assert_contains "$(cat "$GITHUB_PATH")" "$TMP/appmap-bin" "binary dir added to PATH"
reset
DEST="$TMP/appmap-bin" APPMAP_URL="https://example.test/appmap-x" \
  assert_ok "install-appmap (cached)" bash "$ROOT/scripts/install-appmap.sh"
assert_eq "" "$(cat "$MOCK_CURL_LOG")" "cache hit downloads nothing"

# --- install-agent: fresh -> npm install + pre-warm; cached -> no npm ---
reset
AGENT=claude AGENT_PACKAGE=@anthropic-ai/claude-code AGENT_VERSION=9.9.9 PREFIX="$TMP/agent-tools" \
  assert_ok "install-agent (fresh)" bash "$ROOT/scripts/install-agent.sh"
assert_file "$TMP/agent-tools/node_modules/.bin/claude" "agent binary installed"
assert_contains "$(cat "$MOCK_NPM_LOG")" "install --prefix $TMP/agent-tools @anthropic-ai/claude-code@9.9.9" "npm install pinned to the resolved version, optional deps included"
assert_contains "$(cat "$GITHUB_PATH")" "$TMP/agent-tools/node_modules/.bin" "agent bin dir added to PATH"
reset
AGENT=claude AGENT_PACKAGE=@anthropic-ai/claude-code AGENT_VERSION=9.9.9 PREFIX="$TMP/agent-tools" \
  assert_ok "install-agent (cached)" bash "$ROOT/scripts/install-agent.sh"
assert_eq "" "$(cat "$MOCK_NPM_LOG")" "cache hit runs no npm"

# --- install-agent: broken cached install -> wiped and reinstalled ---
reset
printf '#!/bin/sh\necho broken >&2\nexit 1\n' > "$TMP/agent-tools/node_modules/.bin/claude"
chmod +x "$TMP/agent-tools/node_modules/.bin/claude"
AGENT=claude AGENT_PACKAGE=@anthropic-ai/claude-code AGENT_VERSION=9.9.9 PREFIX="$TMP/agent-tools" \
  assert_ok "install-agent (broken cache)" bash "$ROOT/scripts/install-agent.sh"
assert_contains "$(cat "$MOCK_NPM_LOG")" "install --prefix" "broken cached install is reinstalled"
assert_ok "reinstalled agent binary works" "$TMP/agent-tools/node_modules/.bin/claude" --version

finish
