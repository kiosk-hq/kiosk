#!/usr/bin/env bash
# One-shot box prep for the next prod-demo deploy — idempotent, safe to re-run.
#
# Run from a workstation checkout (script travels over stdin, needs no upload):
#
#   ssh ubuntu@kyc.demo.kiosk.tech 'sudo bash -s' < reference/deploy/box-prep-2026-08-11.sh
#
# What it does, and why the next deploy NEEDS it first — it edits ONLY the
# hand-maintained /etc/kiosk-demo/*.env files, which no repo file drives:
#   1. /etc/kiosk-demo/atablefor.env — replaces the three mutually-exclusive
#      legacy PoW flags (KIOSK_POW_DEMO / KIOSK_POW_REPUTATION_DEMO /
#      KIOSK_POW_BACKOFF_DEMO, honoured now only as single-mode aliases) with
#      the single explicit selector KIOSK_POW_MODE=reputation. The current code
#      RAISES at boot when more than one legacy flag is set, so deploying an env
#      that still carries several without this first takes atablefor down.
#   2. All six flag-carrying env files — removes the dead KIOSK_POW_REGISTER_DEMO
#      (registration PoW is unconditional now; the flag reads nowhere).
#
# IT DOES NOT TOUCH CADDY. There is deliberately no per-IP edge throttle on this
# fleet: the PoW verifies in milliseconds, so a flood buys an attacker no CPU
# worth throttling for. /etc/caddy/Caddyfile is owned by deploy/deploy-caddy.sh
# alone and is never hand-edited; the shipped deploy/Caddyfile carries the
# rate-limit snippet COMMENTED OUT for the day that decision is revisited. See
# deploy/README.md §"Edge rate-limit".
#
# Every edited file gets a .bak-2026-08-11 sibling.
set -euo pipefail

STAMP=2026-08-11
APPS_WITH_DEAD_FLAG="atablefor getgrocery hoteling philslist stylish tudu"

echo "== env files =="
for n in $APPS_WITH_DEAD_FLAG; do
  f=/etc/kiosk-demo/$n.env
  [ -f "$f.bak-$STAMP" ] || cp -p "$f" "$f.bak-$STAMP"
done

f=/etc/kiosk-demo/atablefor.env
sed -i -e '/^KIOSK_POW_DEMO=/d' \
       -e '/^KIOSK_POW_REPUTATION_DEMO=/d' \
       -e '/^KIOSK_POW_BACKOFF_DEMO=/d' "$f"
if ! grep -q '^KIOSK_POW_MODE=' "$f"; then
  printf '\n# One explicit PoW policy selector (replaces the legacy KIOSK_POW_DEMO /\n# KIOSK_POW_REPUTATION_DEMO / KIOSK_POW_BACKOFF_DEMO flags - several at once\n# raise at boot). reputation = the flagship anti-scalping showcase.\nKIOSK_POW_MODE=reputation\n' >> "$f"
fi

for n in $APPS_WITH_DEAD_FLAG; do
  sed -i '/^KIOSK_POW_REGISTER_DEMO=/d' /etc/kiosk-demo/$n.env
done

for f in /etc/kiosk-demo/*.env; do
  echo "$(basename "$f"): register_flag=$(grep -cE '^KIOSK_POW_REGISTER_DEMO=' "$f" || true) mode=$(grep -E '^KIOSK_POW_MODE=' "$f" | cut -d= -f2) legacy=$(grep -cE '^KIOSK_POW_(DEMO|REPUTATION_DEMO|BACKOFF_DEMO)=' "$f" || true)"
done

echo "== box prep DONE - safe to push prod-demo =="
