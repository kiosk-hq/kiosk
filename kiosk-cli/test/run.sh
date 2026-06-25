#!/bin/sh
# Unit tests for kiosk-cli/bin/kiosk.
#
# Covers behaviour that doesn't need a live server: help/version, exit codes
# for bad usage, token-resolution error path, host normalization. End-to-end
# coverage against a real kiosk-server lives in oss/e2e/assistant.sh.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
KIOSK="$DIR/../bin/kiosk"

PASS=0
FAIL=0

assert() {
  label="$1"; actual="$2"; expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  \033[1;32m✓\033[0m %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  \033[1;31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n' \
      "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# Run kiosk and capture exit code only (stderr suppressed).
exit_of() {
  "$KIOSK" "$@" >/dev/null 2>&1
  echo $?
}

# Run kiosk and capture stderr line count.
stderr_lines_of() {
  "$KIOSK" "$@" 2>&1 >/dev/null | wc -l | tr -d ' '
}

printf '\n\033[1m=== kiosk-cli unit tests ===\033[0m\n\n'

# ─── help / version ────────────────────────────────────────────────────

printf '\033[1m--- help / version ---\033[0m\n'

assert "--version exits 0"        "$(exit_of --version)" "0"
assert "-V exits 0"               "$(exit_of -V)"        "0"
assert "version verb exits 0"     "$(exit_of version)"   "0"
assert "--help exits 0"           "$(exit_of --help)"    "0"
assert "-h exits 0"               "$(exit_of -h)"        "0"
assert "help verb exits 0"        "$(exit_of help)"      "0"
assert "no args exits 2"          "$(exit_of)"           "2"

version_line=$("$KIOSK" --version 2>&1)
case "$version_line" in
  "kiosk "*)
    printf '  \033[1;32m✓\033[0m --version prints kiosk <version>\n'
    PASS=$((PASS + 1)) ;;
  *)
    printf '  \033[1;31m✗\033[0m --version unexpected: %s\n' "$version_line"
    FAIL=$((FAIL + 1)) ;;
esac

# ─── usage errors (exit 2) ─────────────────────────────────────────────

printf '\n\033[1m--- usage errors ---\033[0m\n'

# No verb after host
assert "host alone exits 2"                 "$(exit_of http://localhost:9999)" "2"

# Missing required args
unset KIOSK_TOKEN
unset KIOSK_TOKEN_LOCALHOST_9999
assert "sql w/o stmt exits 2"               "$(exit_of http://localhost:9999 sql)" "2"
assert "run w/o action exits 2"             "$(exit_of http://localhost:9999 run)" "2"

# Bad arg shape to run
# (token absent → would 3, but k=v parse fails first → 2)
# We force a token-resolution path via env so the verb actually parses args.
KIOSK_TOKEN="dummy" assert "run with non-kv arg exits 2" \
  "$(KIOSK_TOKEN=dummy exit_of http://localhost:9999 run book_appointment notakv)" "2"

# Unknown verb
assert "unknown verb exits 2"               "$(exit_of http://localhost:9999 wat)"   "2"

# Not-yet-implemented verbs map to exit 6 with a clear message
assert "schema verb not impl exits 6"       "$(exit_of http://localhost:9999 schema)" "6"
assert "pay verb not impl exits 6"          "$(exit_of http://localhost:9999 pay foo)" "6"
assert "events verb not impl exits 6"       "$(exit_of http://localhost:9999 events)" "6"

# ─── token resolution (no live server) ────────────────────────────────

printf '\n\033[1m--- token resolution ---\033[0m\n'

# Token never found → exit 3 BEFORE network call
unset KIOSK_TOKEN
unset KIOSK_TOKEN_LOCALHOST_59999
HOME_BACKUP="$HOME"
TMPHOME=$(mktemp -d)
HOME="$TMPHOME"
export HOME

# Trying to talk to a port that doesn't exist would normally take a moment.
# But the CLI fetches /.well-known first; bad host → curl fails → exit 6.
# To isolate the token-resolution path we'd need a mock server (see e2e).
# Here we check the easier inverse: a valid token in env still produces a
# *network* error (exit 6) against unreachable host, NOT auth (exit 3).
assert "unreachable host + token → 6" \
  "$(KIOSK_TOKEN=x exit_of http://localhost:59999 query scooters_available)" "6"

HOME="$HOME_BACKUP"
export HOME

# ─── summary ──────────────────────────────────────────────────────────

printf '\n\033[1m=== summary ===\033[0m\n  pass: %s\n  fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
