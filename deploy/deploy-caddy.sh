#!/usr/bin/env bash
# Deploy deploy/Caddyfile to the demo VPS, declaratively.
#
# Usage: deploy/deploy-caddy.sh            # CHECK: diff + remote validate, changes nothing
#        deploy/deploy-caddy.sh --apply    # install, reload, verify, roll back on failure
#        deploy/deploy-caddy.sh --self-test
#        KIOSK_CADDY_HOST=… to override the host
#
# WHY THIS EXISTS (Phil, 2026-09-06: «предпочтительнее caddy раскатывать через
# какой-то декларативный скрипт. Вот ты сам это и сделай. Это часть демок.»).
#
# Until now /etc/caddy/Caddyfile was HAND-MAINTAINED and deploy/Caddyfile was a
# template nobody applied. That split is not a filing detail — it is the reason
# two separate findings existed at once and neither could be closed by a push:
# the fleet sent no HSTS while the template shipped the header enabled (K-1295),
# and the fleet throttled every request while the template shipped the limiter
# commented out (K-1168/T-171). `git push` moved neither, because prod-demo
# deploys the APPS and has never deployed the EDGE.
#
# THE REPO IS NOW THE SOURCE OF TRUTH. This script makes the box match the file
# and refuses to guess: it never edits in place, never patches a line, and never
# merges. It ships the whole file or it ships nothing.
#
# WHAT MADE THAT SAFE TO DO, and it was checked rather than assumed: the live
# file was read first and is 49 lines, ALL of them Kiosk — eight demo vhosts and
# one snippet, no other sites. deploy/Caddyfile's own header claimed the box
# "also serves other sites", which was FALSE at the time this was written; had it
# been true, owning the whole file would have been the wrong design and this
# would have had to manage a fragment instead.

set -euo pipefail

HOST="${KIOSK_CADDY_HOST:-ubuntu@vps-ecaec54a.vps.ovh.net}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/Caddyfile"
REMOTE_ETC="/etc/caddy/Caddyfile"
STAGE="/tmp/kiosk-caddyfile.staged"

# The eight vhosts, DERIVED from the file being deployed rather than restated.
# A hand-kept copy of this list is the thing that goes stale the first time a
# demo is added, and it would go stale silently: the verify loop would simply
# stop checking the new one.
hosts_from_config() {
  grep -oE '^[a-z0-9.-]+\.demo\.kiosk\.tech \{' "$SRC" | sed 's/ {$//'
}

ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "$@"; }

# ── verification, run against the LIVE wire and not against the config ───────
#
# Reading the file back off the box would prove only that scp works. What has to
# be true is a property of the served response, so that is what is measured.
verify_live() {
  local bad=0 h code hsts
  for h in $(hosts_from_config); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$h/" || echo 000)"
    hsts="$(curl -sSI --max-time 15 "https://$h/" 2>/dev/null | grep -ci '^strict-transport-security' || true)"
    if [[ "$code" != "200" && "$code" != "302" && "$code" != "404" ]]; then
      printf '  FAIL %-34s answered %s\n' "$h" "$code"; bad=1
    elif [[ "$hsts" == "0" ]]; then
      printf '  FAIL %-34s 200 but no Strict-Transport-Security\n' "$h"; bad=1
    else
      printf '  ok   %-34s %s, HSTS present\n' "$h" "$code"
    fi
  done
  return "$bad"
}

# The throttle probe has to burst and then probe a SIBLING while the window is
# still full. Measured 2026-09-05: after a burst the limited origin recovers in
# under a minute, so a sibling probed late answers 200 whether or not the
# limiter exists — a drained window and a removed limiter read identically.
# That false negative is why the sibling call is inside the burst loop.
verify_no_throttle() {
  local first second n=0 code
  first="$(hosts_from_config | head -1)"
  second="$(hosts_from_config | sed -n 2p)"
  [[ -n "$second" ]] || { echo "  skip throttle probe: only one vhost"; return 0; }
  while (( n < 75 )); do
    n=$((n + 1))
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$first/.well-known/kiosk.json" || echo 000)"
    if [[ "$code" == "429" ]]; then
      printf '  FAIL throttle still on: %s answered 429 at request %s\n' "$first" "$n"
      printf '       sibling %s answered %s in the same window\n' "$second" \
        "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$second/.well-known/kiosk.json" || echo 000)"
      return 1
    fi
  done
  printf '  ok   no 429 in %s sequential requests to %s\n' "$n" "$first"
  return 0
}

# ── self-test: exercises the pure parts, touches no host ─────────────────────
if [[ "${1:-}" == "--self-test" ]]; then
  bad=0
  arm() { if [[ "$2" == "$3" ]]; then printf '  OK    %s\n' "$1"; else
    printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; bad=$((bad+1)); fi; }

  n="$(hosts_from_config | wc -l | tr -d ' ')"
  arm "the vhost list is DERIVED from the file, and the file has some" "8" "$n"
  arm "every derived host is a demo subdomain" "" \
      "$(hosts_from_config | grep -v '\.demo\.kiosk\.tech$' | tr '\n' ' ')"
  # Count the DIRECTIVE, not the word: this file explains itself at length, so
  # the header is named in prose as well, and a bare word-count reads 2.
  arm "the config declares HSTS, or deploying it would undo K-1295" "1" \
      "$(grep -cE '^[[:space:]]*header[[:space:]]+Strict-Transport-Security' "$SRC")"
  arm "the config does NOT enable the limiter, or deploying it would undo T-171" "0" \
      "$(grep -cE '^[[:space:]]*import ratelimit' "$SRC" || true)"

  # VACUITY — the KIND is a derivation check, so "the pattern must still match"
  # is the right direction: a hosts_from_config that matches nothing would make
  # verify_live a loop over an empty list, which passes while proving nothing.
  if (( n >= 1 )); then printf '  HIT   vacuity: the host pattern has %s live subject(s)\n' "$n"
  else printf '  FAIL  vacuity: the host pattern matches NOTHING, so verify_live would pass vacuously\n'; bad=$((bad+1)); fi

  tmp="$(mktemp)"; printf 'x.demo.kiosk.tech {\n}\n' >|"$tmp"
  got="$(SRC="$tmp" bash -c 'grep -oE "^[a-z0-9.-]+\.demo\.kiosk\.tech \{" "$SRC" | sed "s/ {$//"')"
  arm "the extractor finds a host in a minimal fixture" "x.demo.kiosk.tech" "$got"
  rm -f "$tmp"

  if (( bad )); then echo "deploy-caddy.sh --self-test: FAILED $bad arm(s)" >&2; exit 1; fi
  echo "deploy-caddy.sh --self-test: OK — the render and the derivation hold. It says NOTHING about the box."
  exit 0
fi

MODE="${1:---check}"
[[ "$MODE" == "--check" || "$MODE" == "--apply" ]] || { echo "usage: $0 [--check|--apply|--self-test]" >&2; exit 2; }

[[ -f "$SRC" ]] || { echo "no config at $SRC" >&2; exit 1; }
echo "deploy-caddy: $SRC -> $HOST:$REMOTE_ETC  (mode $MODE)"

# 1. stage, and validate REMOTELY — the box's caddy is the one whose opinion
#    counts, and it is the only one that has the modules the config may use.
ssh_ "cat > $STAGE" < "$SRC"
if ! ssh_ "caddy validate --adapter caddyfile --config $STAGE" >/dev/null 2>&1; then
  echo "REFUSING: the box's caddy says this config is invalid:" >&2
  ssh_ "caddy validate --adapter caddyfile --config $STAGE" 2>&1 | tail -20 >&2
  exit 1
fi
echo "  validated by caddy on the box"

# 2. diff. Identical means there is nothing to do, and saying so is the point of
#    a declarative deploy: a no-op must be visibly a no-op.
if ssh_ "cmp -s $STAGE $REMOTE_ETC"; then
  echo "  the box already matches this file — nothing to do"
  # The exit code is written out per branch on purpose. The first version of
  # this block ended `[[ "$MODE" == "--apply" ]] && { … }; exit $?`, which under
  # --check made the FALSE test its own exit status: a clean, matching box
  # reported failure. An idempotent deploy whose no-op looks like a fault is one
  # nobody runs twice, which is the whole property it exists to have.
  if [[ "$MODE" == "--apply" ]]; then
    echo; echo "verifying the live wire anyway:"
    if verify_live && verify_no_throttle; then exit 0; else exit 1; fi
  fi
  exit 0
fi
echo "  CHANGES (live -> this file):"
ssh_ "diff -u $REMOTE_ETC $STAGE || true" | sed 's/^/    /' | head -60

if [[ "$MODE" == "--check" ]]; then
  echo; echo "  --check only. Re-run with --apply to install."; exit 0
fi

# 3. back up, install, reload. The backup is what rollback restores; taking it
#    on the box rather than trusting the repo is deliberate, because what must
#    be restorable is what was RUNNING, not what we think was running.
STAMP="$(ssh_ 'date -u +%Y%m%dT%H%M%SZ')"
BACKUP="/etc/caddy/Caddyfile.bak-$STAMP"
ssh_ "sudo cp -p $REMOTE_ETC $BACKUP"
echo "  backed up live config to $BACKUP"
ssh_ "sudo install -m 0644 -o root -g root $STAGE $REMOTE_ETC"
ssh_ "sudo systemctl reload caddy"
echo "  installed and reloaded"

sleep 3

# 4. verify the WIRE, and roll back if it disagrees.
echo "  verifying:"
if verify_live && verify_no_throttle; then
  echo "deploy-caddy: OK — the box matches $SRC and the live wire agrees."
  exit 0
fi

echo "deploy-caddy: VERIFY FAILED — rolling back to $BACKUP" >&2
ssh_ "sudo install -m 0644 -o root -g root $BACKUP $REMOTE_ETC && sudo systemctl reload caddy"
sleep 3
echo "  rolled back; re-verifying the restored config:" >&2
verify_live >&2 || true
exit 1
