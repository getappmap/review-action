#!/usr/bin/env bash
# Install the AppMap CLI as a single prebuilt binary from GitHub releases.
# $DEST is cached by the action keyed on the release version + platform, so a
# cache hit means the binary is already present and nothing is downloaded.
set -euo pipefail

: "${APPMAP_URL:?APPMAP_URL is required}"
: "${DEST:?DEST is required}"

if [[ -x "$DEST/appmap" ]]; then
  echo "AppMap CLI restored from cache."
else
  mkdir -p "$DEST"
  echo "Downloading $APPMAP_URL"
  curl -fsSL "$APPMAP_URL" -o "$DEST/appmap"
  chmod 755 "$DEST/appmap"
fi
echo "appmap: $("$DEST/appmap" --version 2>/dev/null || echo '?')"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$DEST" >> "$GITHUB_PATH"
fi
