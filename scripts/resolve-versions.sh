#!/usr/bin/env bash
# Resolve the tool versions to install, for cache keys and download URLs.
# The AppMap CLI ships as a single prebuilt binary on getappmap/appmap-js
# GitHub releases (the proven legacy install-action channel); the agent CLI
# (Claude Code / Copilot CLI) comes from npm.
#
# Outputs: platform, appmap-preinstalled, appmap-version, appmap-url,
# agent-package, agent-version.
set -euo pipefail

: "${AGENT:?AGENT is required}"

case "$(uname -s)" in
  Linux) os_part=linux ;;
  Darwin) os_part=macos ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 2
    ;;
esac
case "$(uname -m)" in
  x86_64) arch_part=x64 ;;
  aarch64 | arm64) arch_part=arm64 ;;
  *)
    echo "unsupported arch: $(uname -m)" >&2
    exit 2
    ;;
esac
platform="$os_part-$arch_part"

# Precedence: an explicit version pin wins outright; otherwise an appmap
# already on PATH is used as-is (repos that build appmap-js themselves rely on
# this); otherwise resolve the latest release. APPMAP_IGNORE_PREINSTALLED=true
# skips the PATH check (useful when a stale binary lurks on the runner).
appmap_preinstalled=false
appmap_version=""
appmap_url=""
if [[ -n "${APPMAP_CLI_VERSION:-}" ]]; then
  appmap_version="${APPMAP_CLI_VERSION#v}"
elif [[ "${APPMAP_IGNORE_PREINSTALLED:-}" != "true" ]] && command -v appmap >/dev/null 2>&1; then
  appmap_preinstalled=true
  echo "Using pre-installed appmap: $(command -v appmap) ($(appmap --version 2>/dev/null || echo '?'))"
else
  # Newest release named @appland/appmap-v*. The monorepo interleaves other
  # packages' releases, so page until found.
  for page in 1 2 3 4 5 6 7 8 9 10; do
    name="$(gh api "repos/getappmap/appmap-js/releases?per_page=100&page=$page" \
      | jq -r '[.[] | select(.name | startswith("@appland/appmap-v"))][0].name // empty')"
    if [[ -n "$name" ]]; then
      appmap_version="${name#@appland/appmap-v}"
      break
    fi
  done
  if [[ -z "$appmap_version" ]]; then
    echo "error: no @appland/appmap release found in getappmap/appmap-js" >&2
    exit 1
  fi
fi
if [[ "$appmap_preinstalled" != "true" ]]; then
  # Tag is "@appland/appmap-v<version>": '@' and '/' must be URL-encoded.
  appmap_url="https://github.com/getappmap/appmap-js/releases/download/%40appland%2Fappmap-v${appmap_version}/appmap-${platform}"
  echo "AppMap CLI v${appmap_version} (${platform})"
fi

case "$AGENT" in
  claude) agent_package="@anthropic-ai/claude-code" ;;
  copilot) agent_package="@github/copilot" ;;
  *)
    echo "unknown agent: $AGENT (expected 'claude' or 'copilot')" >&2
    exit 2
    ;;
esac
agent_version="$(npm view "$agent_package" version)"
echo "Agent runtime ${agent_package}@${agent_version}"

{
  echo "platform=$platform"
  echo "appmap-preinstalled=$appmap_preinstalled"
  echo "appmap-version=$appmap_version"
  echo "appmap-url=$appmap_url"
  echo "agent-package=$agent_package"
  echo "agent-version=$agent_version"
} >> "$GITHUB_OUTPUT"
