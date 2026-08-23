#!/usr/bin/env bash
# Is this box's edge actually rate-limited? (K-976)
#
# WHY THIS EXISTS. K-540: /kiosk/auth/register is an unauthenticated CPU sink,
# and at the shipped WEB_CONCURRENCY=1 a plain flood of ANY endpoint saturates
# the single Puma worker. The app can make each request cheaper; only something
# in FRONT of the app bounds the request RATE. The Caddyfile in this directory
# carries that backstop -- and ships it COMMENTED OUT, because `rate_limit` is
# not a stock Caddy directive and a stock binary refuses to load the WHOLE
# config naming it ("unrecognized directive: rate_limit", verified on Caddy
# v2.11.2). Shipping it enabled would trade a DoS gap for a guaranteed outage.
#
# So enabling it is a runbook STEP, and a runbook step is a thing a human can
# skip. Before this script, skipping it was SILENT: the box came up, every site
# served, every demo worked, and nothing anywhere said the edge was open. The
# template's own path of least resistance -- copy the file, reload Caddy --
# produced exactly the configuration K-540 exists to prevent.
#
# This script is the loud half. It does not change any config; it reads one and
# answers whether every proxied site reaches a `rate_limit` directive. Run it
# on the box after `caddy validate`, and again after any Caddyfile edit.
#
# USAGE
#   deploy/check-edge-ratelimit.sh [CADDYFILE]     # default /etc/caddy/Caddyfile
#   deploy/check-edge-ratelimit.sh --self-test     # prove the check both ways
#
# THE DOCUMENTED ESCAPE HATCH. The Caddyfile names a per-IP rate rule at a CDN
# or WAF in front of the box as equally acceptable. That is invisible from
# here, so declare it -- `KIOSK_EDGE_RATELIMIT=external` -- and this script
# says so out loud and exits 0. What it will NOT do is pass silently on a box
# where neither exists. "I have one somewhere else" is a claim someone made;
# an unset variable is nobody having thought about it.
#
# PARSING NOTE: comments are stripped as `#` to end of line. The shipped
# Caddyfile uses `#` for nothing else. A config that puts a literal `#` inside
# a quoted value would need a real parser -- `caddy adapt` is that parser, and
# a mis-parse here makes this check FAIL, never pass.

set -euo pipefail

# ---------------------------------------------------------------------------
# Flatten a Caddyfile into "block header -> the directives that block reaches",
# expanding `import <snippet>` up to a small depth. Emits one line per block:
#   <header><TAB><space-separated directive names>
# ---------------------------------------------------------------------------
flatten() {
  local file="$1"
  awk '
    { sub(/#.*$/, "") }                       # strip comments
    { gsub(/\r/, "") }
    /^[[:space:]]*$/ { next }

    depth == 0 && /\{[[:space:]]*$/ {
      header = $0
      sub(/[[:space:]]*\{[[:space:]]*$/, "", header)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", header)
      depth = 1
      body[header] = ""
      current = header
      next
    }

    depth > 0 {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      if (line == "}" && depth == 1) { depth = 0; current = ""; next }
      depth += opens - closes
      if (depth < 1) { depth = 0; current = ""; next }
      split(line, w, /[[:space:]]+/)
      if (w[1] != "" && w[1] != "}" && w[1] != "{") body[current] = body[current] " " w[1] ":" w[2]
      next
    }
    END {
      for (h in body) printf "%s\t%s\n", h, body[h]
    }
  ' "$file"
}

check() {
  local file="$1"
  local flat uncovered=0 proxied=0 rate_limit_defined=0

  [ -r "$file" ] || { echo "check-edge-ratelimit: cannot read $file" >&2; return 2; }
  flat="$(flatten "$file")"

  # Snippet name -> its directives, for one level of `import` expansion.
  # (The shipped file is exactly one level deep: site -> kioskproxy -> ratelimit.)
  # Expand `import <snippet>` to a FIXPOINT, not one level: the shipped file is
  # site -> (kioskproxy) -> (ratelimit), so a single-level expansion sees the
  # import and never the rate_limit behind it. Bounded at 5 rounds so a
  # mutually-recursive pair of snippets cannot hang the check.
  resolve() { # $1 = block header
    local out seen round tok name snippet add
    out="$(printf '%s\n' "$flat" | awk -F'\t' -v h="$1" '$1 == h { print $2; exit }')"
    seen=" $1 "
    for round in 1 2 3 4 5; do
      add=""
      for tok in $out; do
        name="${tok%%:*}"
        [ "$name" = "import" ] || continue
        snippet="(${tok#*:})"
        [ "$snippet" = "()" ] && continue
        case "$seen" in *" $snippet "*) continue ;; esac
        seen="$seen$snippet "
        add="$add $(printf '%s\n' "$flat" | awk -F'\t' -v h="$snippet" '$1 == h { print $2; exit }')"
      done
      [ -n "${add// /}" ] || break
      out="$out $add"
    done
    printf '%s' "$out"
  }

  # Is a rate_limit directive DEFINED anywhere active at all?
  printf '%s\n' "$flat" | grep -q ' rate_limit:' && rate_limit_defined=1

  local header dirs
  while IFS=$'\t' read -r header dirs; do
    case "$header" in
      "("*")") continue ;;   # snippet definition, not a site
      "")      continue ;;
    esac
    dirs="$(resolve "$header")"
    case " $dirs " in *" reverse_proxy:"*) ;; *) continue ;; esac
    proxied=$((proxied + 1))
    case " $dirs " in
      *" rate_limit:"*) ;;
      *) uncovered=$((uncovered + 1)); echo "  UNCOVERED  $header" ;;
    esac
  done <<< "$flat"

  if [ "$proxied" -eq 0 ]; then
    echo "check-edge-ratelimit: $file defines no proxied site — nothing to check, and that is not a pass." >&2
    return 2
  fi

  if [ "$uncovered" -eq 0 ]; then
    echo "check-edge-ratelimit: OK — all $proxied proxied site(s) in $file reach a rate_limit directive."
    return 0
  fi

  {
    echo
    echo "check-edge-ratelimit: FAIL — $uncovered of $proxied proxied site(s) have NO edge rate limit."
    echo
    if [ "$rate_limit_defined" -eq 0 ]; then
      echo "  No active rate_limit directive exists in $file at all: the (ratelimit)"
      echo "  snippet is still commented out, which is how it SHIPS."
    else
      echo "  A rate_limit directive exists, but the sites above never reach it —"
      echo "  check that (kioskproxy) still carries its 'import ratelimit' line."
    fi
    echo
    echo "  This is the K-540 exposure: /kiosk/auth/register is unauthenticated and"
    echo "  CPU-bound, and at WEB_CONCURRENCY=1 one laptop can saturate the worker."
    echo
    echo "  TO FIX, both halves, then 'caddy validate' and reload:"
    echo "    1. sudo caddy add-package github.com/mholt/caddy-ratelimit   # Caddy >= 2.7"
    echo "       sudo systemctl restart caddy"
    echo "       caddy list-modules | grep rate_limit                      # must print it"
    echo "    2. uncomment 'import ratelimit' inside (kioskproxy) AND the whole"
    echo "       (ratelimit) snippet in $file"
    echo
    echo "  IF the rate limiting is genuinely somewhere else — a CDN or WAF in front"
    echo "  of this box, which deploy/README.md accepts as equivalent — say so:"
    echo "    KIOSK_EDGE_RATELIMIT=external deploy/check-edge-ratelimit.sh $file"
  } >&2
  return 1
}

self_test() {
  local here template tmp rc fails=0
  here="$(cd "$(dirname "$0")" && pwd)"
  template="$here/Caddyfile"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # (1) The template AS SHIPPED must FAIL. If this ever passes, either the
  #     backstop was uncommented in the repo (which breaks a stock install) or
  #     this check went blind.
  rc=0; check "$template" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "  ok   shipped deploy/Caddyfile is reported UNPROTECTED (exit 1)"
  else
    echo "  FAIL shipped deploy/Caddyfile should exit 1, got $rc"; fails=$((fails + 1))
  fi

  # (2) The same file with the two blocks uncommented must PASS.
  # Uncomment the two blocks the same way an operator does: the `import
  # ratelimit` line inside (kioskproxy), and every line of the (ratelimit)
  # snippet from its header to its closing brace. Written in awk rather than
  # sed because BSD sed has no \t.
  awk '
    /^[[:space:]]*# import ratelimit/ {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) "import ratelimit"
      next
    }
    /^# \(ratelimit\) \{/ { inblock = 1 }
    inblock {
      line = $0
      sub(/^#[[:space:]]?/, "", line)
      print line
      if (line ~ /^\}/) inblock = 0
      next
    }
    { print }
  ' "$template" > "$tmp/enabled"
  rc=0; check "$tmp/enabled" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ok   the same file with the backstop enabled is reported PROTECTED (exit 0)"
  else
    echo "  FAIL enabled Caddyfile should exit 0, got $rc"; fails=$((fails + 1))
    check "$tmp/enabled" || true
  fi

  # (3) A site that proxies WITHOUT importing (kioskproxy) must be caught, so
  #     the check answers per-site rather than "is rate_limit mentioned".
  { cat "$tmp/enabled"; printf '\nrogue.demo.kiosk.tech {\n\treverse_proxy 127.0.0.1:3999\n}\n'; } > "$tmp/rogue"
  rc=0; check "$tmp/rogue" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "  ok   a site that proxies without the snippet is caught even when rate_limit exists"
  else
    echo "  FAIL rogue site should exit 1, got $rc"; fails=$((fails + 1))
  fi

  # (4) The escape hatch is honoured, and only when declared.
  rc=0; KIOSK_EDGE_RATELIMIT=external "$0" "$template" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ok   KIOSK_EDGE_RATELIMIT=external is accepted for the shipped template"
  else
    echo "  FAIL declared-external should exit 0, got $rc"; fails=$((fails + 1))
  fi

  if [ "$fails" -eq 0 ]; then
    echo "check-edge-ratelimit --self-test: OK — 4 assertions, all passed."
    return 0
  fi
  echo "check-edge-ratelimit --self-test: $fails assertion(s) FAILED." >&2
  return 1
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  -h|--help)   sed -n '1,40p' "$0"; exit 0 ;;
esac

CADDYFILE="${1:-/etc/caddy/Caddyfile}"

if [ "${KIOSK_EDGE_RATELIMIT:-}" = "external" ]; then
  echo "check-edge-ratelimit: SKIPPED — KIOSK_EDGE_RATELIMIT=external."
  echo "  You have declared that a CDN or WAF in front of this box rate-limits"
  echo "  /kiosk/* per IP. Nothing here can see that, so nothing here verifies it."
  echo "  If that is not true, this box's register endpoint is an open CPU sink."
  exit 0
fi

check "$CADDYFILE"
