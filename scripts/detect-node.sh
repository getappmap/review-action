#!/usr/bin/env bash
# Decide whether the action must install Node. The agent CLIs and the bundled
# usage script run on Node; if the enclosing workflow already provides `node`
# at the required major version or newer, it is used as-is.
#
# Outputs: need-node (true/false), node-major (the major version that will be
# in effect — used in the agent cache key).
set -euo pipefail

: "${NODE_MIN:?NODE_MIN is required}"

min_major="${NODE_MIN%%.*}"
need=true
major=""
if command -v node >/dev/null 2>&1; then
  v="$(node --version 2>/dev/null || true)" # e.g. v22.1.0
  v="${v#v}"
  major="${v%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]] && ((major >= min_major)); then
    need=false
    echo "Using the workflow's node v$v (>= $min_major)."
  fi
fi
if [[ "$need" == "true" ]]; then
  major="$min_major"
  echo "No node >= $min_major on PATH; the action will install Node $NODE_MIN."
fi

{
  echo "need-node=$need"
  echo "node-major=$major"
} >> "$GITHUB_OUTPUT"
