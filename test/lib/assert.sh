#!/usr/bin/env bash
# Tiny assertion helpers for the review-action test suites. No dependencies.
#
# A suite sources this file, runs cases, and calls the assert_* helpers. Each
# failed assertion prints a message and increments a failure counter; the suite
# exits non-zero if any assertion failed (via `finish`).

ASSERT_FAILURES=0
ASSERT_COUNT=0

_red()   { printf '\033[31m%s\033[0m' "$1"; }
_green() { printf '\033[32m%s\033[0m' "$1"; }

pass() { ASSERT_COUNT=$((ASSERT_COUNT + 1)); printf '  %s %s\n' "$(_green ✓)" "$1"; }
failed() {
  ASSERT_COUNT=$((ASSERT_COUNT + 1))
  ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
  printf '  %s %s\n' "$(_red ✗)" "$1"
}

assert_eq() { # expected actual [msg]
  if [[ "$1" == "$2" ]]; then pass "${3:-equals: $1}"
  else failed "${3:-equals}: expected [$1] got [$2]"; fi
}

assert_contains() { # haystack needle [msg]
  if [[ "$1" == *"$2"* ]]; then pass "${3:-contains: $2}"
  else failed "${3:-contains}: [$2] not found in output"; fi
}

assert_not_contains() { # haystack needle [msg]
  if [[ "$1" != *"$2"* ]]; then pass "${3:-not contains: $2}"
  else failed "${3:-not contains}: [$2] unexpectedly found"; fi
}

assert_file() { # path [msg]
  if [[ -f "$1" ]]; then pass "${2:-file exists: $1}"
  else failed "${2:-file exists}: $1 missing"; fi
}

assert_no_file() { # path [msg]
  if [[ ! -e "$1" ]]; then pass "${2:-absent: $1}"
  else failed "${2:-absent}: $1 exists"; fi
}

assert_symlink() { # path [msg]
  if [[ -L "$1" ]]; then pass "${2:-symlink: $1}"
  else failed "${2:-symlink}: $1 is not a symlink"; fi
}

# Run a command; assert it exits 0. Captures output in $LAST_OUTPUT.
assert_ok() { # msg cmd...
  local msg="$1"; shift
  if LAST_OUTPUT="$("$@" 2>&1)"; then pass "$msg (exit 0)"
  else failed "$msg: expected success, got exit $? — $LAST_OUTPUT"; fi
}

# Run a command; assert it exits non-zero. Captures output in $LAST_OUTPUT.
assert_fail() { # msg cmd...
  local msg="$1"; shift
  if LAST_OUTPUT="$("$@" 2>&1)"; then
    failed "$msg: expected failure, but it succeeded — $LAST_OUTPUT"
  else pass "$msg (non-zero exit)"; fi
}

finish() {
  echo
  if [[ "$ASSERT_FAILURES" -eq 0 ]]; then
    printf '%s %d assertions passed\n' "$(_green PASS)" "$ASSERT_COUNT"
    exit 0
  else
    printf '%s %d/%d assertions failed\n' "$(_red FAIL)" "$ASSERT_FAILURES" "$ASSERT_COUNT"
    exit 1
  fi
}
