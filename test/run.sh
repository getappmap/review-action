#!/usr/bin/env bash
# Run the review-action self-test suites. Offline, no API keys, no network.
#
# Usage: test/run.sh [suite-name ...]
#   With no args, runs every test/suites/*.test.sh.
#   With args, runs only the named suites (with or without the .test.sh suffix).
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Make mocks and scripts executable (git may not preserve the bit everywhere).
chmod +x "$TEST_DIR"/mocks/* "$ROOT"/scripts/*.sh 2>/dev/null || true

suites=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do
    f="$TEST_DIR/suites/${name%.test.sh}.test.sh"
    suites+=("$f")
  done
else
  for f in "$TEST_DIR"/suites/*.test.sh; do suites+=("$f"); done
fi

failed=0
for suite in "${suites[@]}"; do
  if [[ ! -f "$suite" ]]; then
    echo "no such suite: $suite" >&2
    failed=$((failed + 1))
    continue
  fi
  bash "$suite" || failed=$((failed + 1))
  echo
done

if [[ "$failed" -eq 0 ]]; then
  echo "All suites passed."
else
  echo "$failed suite(s) failed." >&2
fi
exit $(( failed > 0 ? 1 : 0 ))
