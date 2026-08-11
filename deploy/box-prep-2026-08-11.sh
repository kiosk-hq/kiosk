#!/usr/bin/env bash
# One-shot box prep for the next prod-demo deploy — idempotent, safe to re-run.
#
# Run from a workstation checkout (script travels over stdin, needs no upload):
#
#   ssh ubuntu@kyc.demo.kiosk.tech 'sudo bash -s' < reference/deploy/box-prep-2026-08-11.sh
#
# What it does, and why the next deploy NEEDS it first:
#   1. /etc/kiosk-demo/atablefor.env — replaces the three mutually-exclusive
#      legacy PoW flags (KIOSK_POW_DEMO / KIOSK_POW_REPUTATION_DEMO /
#      KIOSK_POW_BACKOFF_DEMO, all currently set at once) with the single
#      explicit selector KIOSK_POW_MODE=reputation. The current code RAISES at
#      boot when more than one legacy flag is set, so deploying without this
#      takes atablefor down.
#   2. All six flag-carrying env files — removes the dead KIOSK_POW_REGISTER_DEMO
#      (registration PoW is unconditional now; the flag reads nowhere).
#   3. Caddy — installs the third-party rate_limit module (caddy add-package),
#      holds the apt package (an unattended apt upgrade would swap back to a
#      stock binary, which REFUSES to start on a config naming rate_limit —
#      that would take every vhost down), inserts the per-IP 60 req/min
#      backstop from deploy/Caddyfile into the hand-maintained
#      /etc/caddy/Caddyfile, validates, restarts, and proves the limit fires.
#
# Every edited file gets a .bak-2026-08-11 sibling; a failed Caddy validate or
# restart auto-restores the backup and exits non-zero.
set -euo pipefail

STAMP=2026-08-11
APPS_WITH_DEAD_FLAG="atablefor getgrocery hoteling philslist stylish tudu"

echo "== 1/3 env files =="
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

echo "== 2/3 caddy rate_limit module =="
if ! caddy list-modules 2>/dev/null | grep -q 'rate_limit'; then
  caddy add-package github.com/mholt/caddy-ratelimit
fi
caddy list-modules | grep rate_limit
# Keep apt from silently swapping the module-bearing binary back to stock.
# To upgrade Caddy later: apt-mark unhold caddy && apt upgrade caddy &&
# caddy add-package github.com/mholt/caddy-ratelimit && apt-mark hold caddy.
apt-mark hold caddy >/dev/null 2>&1 || true

echo "== 3/3 Caddyfile =="
CF=/etc/caddy/Caddyfile
[ -f "$CF.bak-$STAMP" ] || cp -p "$CF" "$CF.bak-$STAMP"

if ! grep -q 'rate_limit' "$CF"; then
  awk '
    # a vhost opener: "host.name {" (not the bare "{" of the global block)
    /^[a-z0-9.-]+[[:space:]]*\{[[:space:]]*$/ {
      if (!snippet_done) {
        print "# Per-IP 60 req/min backstop (deploy/Caddyfile (ratelimit) snippet)."
        print "# Far above an honest agent'\''s pace, far below worker saturation."
        print "(ratelimit) {"
        print "\trate_limit {"
        print "\t\tzone kiosk_per_ip {"
        print "\t\t\tkey    {remote_host}"
        print "\t\t\tevents 60"
        print "\t\t\twindow 1m"
        print "\t\t}"
        print "\t}"
        print "}"
        print ""
        snippet_done = 1
      }
      print
      print "\timport ratelimit"
      next
    }
    { print }
  ' "$CF" > /tmp/Caddyfile.new-$STAMP
  mv /tmp/Caddyfile.new-$STAMP "$CF"
fi

if ! caddy validate --config "$CF"; then
  echo "!! validate FAILED - restoring backup" >&2
  cp -p "$CF.bak-$STAMP" "$CF"
  systemctl restart caddy
  exit 1
fi
# restart, not reload: add-package swapped the binary
systemctl restart caddy
sleep 2
if ! systemctl is-active --quiet caddy; then
  echo "!! caddy not active after restart - restoring backup" >&2
  cp -p "$CF.bak-$STAMP" "$CF"
  systemctl restart caddy
  exit 1
fi

echo "== verify vhosts =="
for h in getgrocery atablefor hoteling skooti stylish philslist tudu kyc; do
  printf '%s %s\n' "$(curl -sS -o /dev/null -w '%{http_code}' "https://$h.demo.kiosk.tech/")" "$h"
done

echo "== verify the limit fires (70 quick hits from this box's own IP) =="
for i in $(seq 1 70); do
  curl -s -o /dev/null -w '%{http_code}\n' https://getgrocery.demo.kiosk.tech/robots.txt
done | sort | uniq -c
echo "(429s above prove the limit; this box's own IP is throttled for <=1 min now)"

echo "== box prep DONE - safe to push prod-demo =="
