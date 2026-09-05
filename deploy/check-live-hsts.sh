#!/usr/bin/env bash
# Does the DEPLOYED fleet actually send HSTS? (K-1295)
#
# WHY THIS EXISTS, and it is a diagnosis rather than a feature request. Two
# halves of one class were filed together: the edge rate limit and HSTS. The
# rate limit got a SCRIPT and it landed. HSTS got a line in deploy/CHECKLIST.md,
# which is 0 ticked of 45, so its tick state carried no information at all. A
# checklist line is not a mechanism.
#
# MEASURED 2026-09-05, all eight origins:
#   curl -sSI https://<host>/ | grep -ci '^strict-transport-security'  ->  0
#
# while deploy/Caddyfile's (kioskproxy) snippet had shipped the header, ENABLED,
# since K-916. The template was right and the box was stale, because nothing
# deployed the template: /etc/caddy/Caddyfile was hand-maintained.
#
# FIXED 2026-09-06 by deploy/deploy-caddy.sh, which installs this directory's
# Caddyfile whole and verifies the wire. Re-measured the same day: 8 of 8 send
# the header. THIS SCRIPT IS NOT RETIRED BY THAT and must not be -- the deploy
# proves the header arrives at the moment it runs, and this proves it still
# arrives now, from anywhere, without ssh.
#
# WHY IT PROBES THE WIRE RATHER THAN PARSING A CONFIG. Its retired sibling
# (deploy/check-edge-ratelimit.sh, gone with the default throttle it asserted)
# answered "does this config reach a directive", which is the right question for
# a directive that cannot be observed without flooding the box. HSTS is on every
# single response, so the strongest available oracle is the response itself --
# and it is the oracle that caught this: a config check run on the template
# would have said OK for as long as the box was serving without it.
#
# WHAT IT CANNOT SEE, said plainly:
#   * Anything about a response the origin did not produce. An edge-generated
#     refusal is invisible here. When the fleet ran a per-IP throttle that was
#     deliberate -- reaching one would have cost 60+ requests against a bucket
#     shared across every demo vhost, i.e. a self-inflicted outage on the whole
#     fleet to observe one header. There is no default throttle any more
#     (T-171), so today it is simply out of scope rather than avoided.
#   * Whether HSTS came from Caddy, from a CDN, or from the app. It answers
#     "does the client get one", which is the only thing a client can act on.
#   * kiosk.tech itself, unless you pass it. That host is GitHub Pages, not this
#     box, so its absent HSTS is a different owner's setting and not something
#     deploy/Caddyfile can fix. Pass it explicitly to see it reported.
#
# USAGE
#   deploy/check-live-hsts.sh                  # every vhost in deploy/Caddyfile
#   deploy/check-live-hsts.sh HOST [HOST...]   # only these
#   deploy/check-live-hsts.sh --self-test      # fixtures + a vacuity arm
#
# THE POLICY IT ENFORCES is the template's own: max-age at least one year and
# `includeSubDomains`. `preload` is deliberately NOT required -- the Caddyfile
# argues that submitting demo hosts to the browser preload list is irreversible
# on any useful timescale.

set -euo pipefail

MIN_MAX_AGE=31536000     # one year, the value deploy/Caddyfile ships

# ---------------------------------------------------------------------------
# judge: read one response's headers on stdin, answer OK / a reason.
# Factored out because it is the only part a --self-test can drive: the fleet
# is not a thing a test may break and put back.
# ---------------------------------------------------------------------------
judge() {
  local hsts age
  hsts="$(tr -d '\r' | grep -i '^strict-transport-security:' | head -1 | cut -d: -f2- || true)"
  hsts="$(printf '%s' "$hsts" | sed 's/^[[:space:]]*//')"

  if [ -z "$hsts" ]; then
    echo "no Strict-Transport-Security header at all"
    return 1
  fi

  age="$(printf '%s' "$hsts" | tr 'A-Z' 'a-z' | sed -n 's/.*max-age=\([0-9][0-9]*\).*/\1/p')"
  if [ -z "$age" ]; then
    echo "Strict-Transport-Security carries no max-age: ${hsts}"
    return 1
  fi
  if [ "$age" -lt "$MIN_MAX_AGE" ]; then
    echo "max-age=${age} is below the ${MIN_MAX_AGE} deploy/Caddyfile ships: ${hsts}"
    return 1
  fi
  if ! printf '%s' "$hsts" | tr 'A-Z' 'a-z' | grep -q 'includesubdomains'; then
    echo "no includeSubDomains: ${hsts}"
    return 1
  fi

  echo "$hsts"
  return 0
}

# ---------------------------------------------------------------------------
# The hosts to probe, DERIVED from deploy/Caddyfile's own vhost blocks rather
# than listed here: a demo added to the fleet must not be invisible to this
# check because someone forgot a second list.
# ---------------------------------------------------------------------------
hosts_from_caddyfile() {
  local file="$1"
  [ -r "$file" ] || return 0
  sed 's/#.*$//' "$file" \
    | grep -E '^[a-z0-9.-]+\.[a-z]+[[:space:]]*\{[[:space:]]*$' \
    | sed 's/[[:space:]]*{[[:space:]]*$//' \
    | sed 's/[[:space:]]*$//' \
    | sort -u
}

probe() {
  local hosts=("$@")
  local host reason rc bad=0 n=0

  if [ "${#hosts[@]}" -eq 0 ]; then
    {
      echo "check-live-hsts: FAIL — no hosts to probe."
      echo "  The host list is derived from deploy/Caddyfile's vhost blocks; an empty list means"
      echo "  the derivation stopped matching, not that the fleet is fine. A probe that probes"
      echo "  nothing is not a pass."
    } >&2
    return 2
  fi

  for host in "${hosts[@]}"; do
    n=$((n + 1))
    rc=0
    reason="$(curl -sSI --max-time 15 "https://${host}/" 2>/dev/null | judge)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "  OK         ${host}  ${reason}"
    else
      bad=$((bad + 1))
      echo "  NO HSTS    ${host}  ${reason:-unreachable}"
    fi
  done

  if [ "$bad" -eq 0 ]; then
    echo "check-live-hsts: OK — all ${n} origin(s) send HSTS with max-age >= ${MIN_MAX_AGE} and includeSubDomains."
    return 0
  fi

  {
    echo
    echo "check-live-hsts: FAIL — ${bad} of ${n} origin(s) send no usable HSTS."
    echo
    echo "  deploy/Caddyfile's (kioskproxy) snippet ships the header ENABLED and every vhost"
    echo "  imports that snippet, so a box running this file has it. If an origin above does"
    echo "  not, the box is NOT running this file."
    echo
    echo "  Do not paste the header onto the box by hand -- the next deploy overwrites the"
    echo "  whole file and the fix disappears. Deploy the repo copy instead:"
    echo
    echo "      deploy/deploy-caddy.sh            # diff + remote validate, changes nothing"
    echo "      deploy/deploy-caddy.sh --apply    # install, reload, verify, roll back on failure"
    echo
    echo "  then re-run this script. If the diff is empty and the header is still missing,"
    echo "  the snippet or its import has been removed from deploy/Caddyfile itself."
    echo
    echo "  A host that is simply unreachable is reported here too, and on purpose: this"
    echo "  script cannot tell 'no header' from 'no answer', and neither can a browser."
  } >&2
  return 1
}

self_test() {
  local fails=0 out rc here template hosts

  # ── BREAK-shaped arms: the judging function against fixtures. The live fleet
  #    is not something a test may break and restore, so what is exercised is
  #    the only part that decides anything.
  arm() { # $1 = label, $2 = expected rc, $3 = header blob
    local rc=0 out
    out="$(printf '%s' "$3" | judge)" || rc=$?
    if [ "$rc" -eq "$2" ]; then
      echo "  ok   $1"
    else
      echo "  FAIL $1 — wanted rc $2, got $rc ($out)"
      fails=$((fails + 1))
    fi
  }

  arm "a compliant header passes" 0 \
      $'HTTP/2 200\r\nstrict-transport-security: max-age=31536000; includeSubDomains\r\n'
  arm "THE MEASURED FLEET STATE — no header at all — fails" 1 \
      $'HTTP/2 200\r\nserver: Caddy\r\ncontent-type: text/html\r\n'
  arm "a header with no max-age fails" 1 \
      $'HTTP/2 200\r\nstrict-transport-security: includeSubDomains\r\n'
  arm "a max-age below one year fails" 1 \
      $'HTTP/2 200\r\nstrict-transport-security: max-age=300; includeSubDomains\r\n'
  arm "a year without includeSubDomains fails" 1 \
      $'HTTP/2 200\r\nstrict-transport-security: max-age=31536000\r\n'
  arm "case and spacing do not matter" 0 \
      $'HTTP/2 200\r\nSTRICT-TRANSPORT-SECURITY:   max-age=31536000; IncludeSubDomains\r\n'

  # ── VACUITY: the host derivation stops matching, so the probe would report
  #    "all fine" over an empty fleet. That must FAIL, not pass — it is the
  #    same shape as a grep whose pattern no longer matches anything.
  rc=0; out="$(probe 2>&1)" || rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "not a pass"; then
    echo "  ok   VACUITY — an empty host list is a failure, not an all-clear"
  else
    echo "  FAIL VACUITY — an empty host list gave rc $rc: $out"
    fails=$((fails + 1))
  fi

  # ── And the derivation itself still finds the fleet in the shipped template.
  here="$(cd "$(dirname "$0")" && pwd)"
  template="$here/Caddyfile"
  hosts="$(hosts_from_caddyfile "$template" | wc -l | tr -d ' ')"
  if [ "$hosts" -ge 8 ]; then
    echo "  ok   VACUITY — deploy/Caddyfile still yields ${hosts} vhost(s) to probe"
  else
    echo "  FAIL VACUITY — deploy/Caddyfile yielded ${hosts} vhost(s); the derivation has gone blind"
    fails=$((fails + 1))
  fi

  if [ "$fails" -eq 0 ]; then
    echo "check-live-hsts --self-test: OK — 8 assertions (6 fixtures, 2 vacuity), all passed."
    return 0
  fi
  echo "check-live-hsts --self-test: $fails assertion(s) FAILED." >&2
  return 1
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  -h|--help)   sed -n '1,45p' "$0"; exit 0 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -gt 0 ]; then
  probe "$@"
else
  # `read -r -a` rather than word-splitting: hosts never contain spaces, but a
  # derivation that silently produced one should not become two arguments.
  HOSTS=()
  while IFS= read -r h; do [ -n "$h" ] && HOSTS+=("$h"); done < <(hosts_from_caddyfile "$HERE/Caddyfile")
  probe "${HOSTS[@]}"
fi
