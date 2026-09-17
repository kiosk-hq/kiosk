#!/usr/bin/env bash
# KYC operator pairing audit — run ON THE BOX, read-only by default.
#
#   ssh <deploy-user>@<box> 'sudo bash -s' < deploy/kyc-pairing-audit.sh
#   ssh <deploy-user>@<box> 'sudo bash -s' -- --fix-retired-names \
#       < deploy/kyc-pairing-audit.sh
#
# WHY IT EXISTS. `bin/check-kyc-operator-pairing` holds the shipped templates
# and the checklist, and its header says in as many words what it cannot see:
# the VALUES on the boxes. Nothing in this repository reads
# /etc/kiosk-demo/*.env, so a deployment can satisfy every rule that guard has
# and still answer `501 module_not_served` on `request_kyc` — which is exactly
# what both KYC operators did for thirty-five days, and what a live third-party
# assistant hit on 2026-09-17.
#
# The half nothing held was the 2026-08-13 rename: the operator side
# read `KIOSK_PROVE_<OP>_SECRET` until then and reads the role-named
# `KIOSK_PROVE_INTAKE_SECRET` now. The rename shipped with a CHANGELOG sentence
# asking deploys to rename the variable, and with no mechanism at all — so both
# operator envs went on carrying a correct secret under a name the app had
# stopped reading. The app then fails CLOSED and SILENTLY: the descriptor keeps
# advertising `request_kyc` because it is static, the verb answers a cacheable
# 501, and the broker answers an unregistered operator and a wrong secret with
# the identical 401. No outside probe separates any of those.
#
# NO VALUE IS EVER PRINTED. Pairing is reported as PAIRED / MISMATCH, presence
# as set / unset. The one thing it prints about a key is a SPKI fingerprint,
# which is public by construction — the broker serves the key at /prove_key.pem.
#
# Exit 0 when every rule holds, 1 otherwise. Safe to re-run.
set -uo pipefail

REPO=${KIOSK_REPO:-/srv/kiosk}
ENVDIR=${KIOSK_ENV_DIR:-/etc/kiosk-demo}
BROKER_ENV=$ENVDIR/prove.env
FIX=0
[ "${1:-}" = "--fix-retired-names" ] && FIX=1

fail=0
bad() { echo "FAIL  $*"; fail=1; }
ok()  { echo "ok    $*"; }

# A demo is a KYC operator iff it ships app/services/prove_broker_client.rb —
# the same derivation bin/check-kyc-operator-pairing's KP-1 makes from the tree.
roster=$(cd "$REPO" 2>/dev/null && ls -d kiosk-demo-*/app/services/prove_broker_client.rb 2>/dev/null |
         sed -e 's|^kiosk-demo-||' -e 's|/app/.*$||' | sort)
if [ -z "$roster" ]; then
  echo "FAIL  no KYC operator found under $REPO (set KIOSK_REPO to the checkout)"
  exit 1
fi
echo "roster: $(echo "$roster" | tr '\n' ' ')"
echo "broker env: $BROKER_ENV"
echo

# Read one variable out of an env file without letting it reach a log line.
# The templates are shell-source-safe by design (deploy/README.md step 3).
val() { ( set -a; . "$1" >/dev/null 2>&1; set +a; eval "printf '%s' \"\${$2-}\"" ) }
spki() { openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}'; }

[ -r "$BROKER_ENV" ] || { echo "FAIL  cannot read $BROKER_ENV (run me under sudo)"; exit 1; }

# The public half the broker actually signs with, as a fingerprint.
broker_fp=$(val "$BROKER_ENV" PROVE_KEY_PEM | openssl pkey -pubout -outform DER 2>/dev/null |
            openssl dgst -sha256 | awk '{print $NF}')
if [ -z "$broker_fp" ]; then
  bad "broker PROVE_KEY_PEM is unset or does not parse as a private key"
else
  ok "broker PROVE_KEY_PEM public half spki-sha256=$broker_fp"
fi

seen_ops=""
for op in $roster; do
  OP=$(echo "$op" | tr '[:lower:]' '[:upper:]')
  f=$ENVDIR/$op.env
  echo "--- $op ---"
  [ -r "$f" ] || { bad "$op: cannot read $f"; continue; }

  # 1. the retired spelling — the whole of the box half. Renaming it is
  #    right only when nothing already assigns the role-named variable; two
  #    assignments of one name in an EnvironmentFile silently take the last.
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?KIOSK_PROVE_${OP}_SECRET=" "$f"; then
    if [ "$FIX" = 1 ]; then
      bk=$f.bak-kyc-intake-rename
      [ -f "$bk" ] || cp -p "$f" "$bk"
      [ -f "$bk" ] || { bad "$op: backup $bk was not created — refusing to edit"; continue; }
      tmp=$f.tmp-kyc-intake-rename
      if grep -qE "^[[:space:]]*(export[[:space:]]+)?KIOSK_PROVE_INTAKE_SECRET=" "$f"; then
        sed -E "/^[[:space:]]*(export[[:space:]]+)?KIOSK_PROVE_${OP}_SECRET=/d" "$f" > "$tmp"
        act="deleted KIOSK_PROVE_${OP}_SECRET (KIOSK_PROVE_INTAKE_SECRET was already assigned)"
      else
        sed -E "s|^([[:space:]]*)(export[[:space:]]+)?KIOSK_PROVE_${OP}_SECRET=|\\1\\2KIOSK_PROVE_INTAKE_SECRET=|" "$f" > "$tmp"
        act="renamed KIOSK_PROVE_${OP}_SECRET -> KIOSK_PROVE_INTAKE_SECRET"
      fi
      if [ -s "$tmp" ]; then cat "$tmp" > "$f"; rm -f "$tmp"; echo "      $act in $f (backup $bk)"
      else rm -f "$tmp"; bad "$op: rewrite produced an empty file — $f left untouched"; fi
    else
      bad "$op: $f still assigns the retired KIOSK_PROVE_${OP}_SECRET — nothing reads it since 2026-08-13; re-run with --fix-retired-names"
    fi
  fi
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?KIOSK_PROVE_${OP}_SECRET=" "$f"; then
    bad "$op: retired KIOSK_PROVE_${OP}_SECRET still present"
  else
    ok "$op: no retired operator-side secret name"
  fi

  # 2. the role-named secret the app actually reads
  s=$(val "$f" KIOSK_PROVE_INTAKE_SECRET)
  if [ -z "$s" ]; then
    bad "$op: KIOSK_PROVE_INTAKE_SECRET unset or empty — request_kyc will answer 501 module_not_served"
  else
    ok "$op: KIOSK_PROVE_INTAKE_SECRET set"
  fi

  # 3. the broker's registry entry for it, and the pairing BY VALUE
  b=$(val "$BROKER_ENV" "KIOSK_PROVE_${OP}_SECRET")
  if [ -z "$b" ]; then
    bad "$op: broker has no KIOSK_PROVE_${OP}_SECRET — OperatorRegistry omits an operator whose secret is blank, so every intake 401s"
  elif [ -n "$s" ] && [ "$s" = "$b" ]; then
    ok "$op: operator secret PAIRED with the broker's registry entry"
  elif [ -n "$s" ]; then
    bad "$op: operator secret MISMATCH against the broker's KIOSK_PROVE_${OP}_SECRET"
  fi
  for prev in $seen_ops; do
    if [ -n "$b" ] && [ "$b" = "$(val "$BROKER_ENV" "KIOSK_PROVE_${prev}_SECRET")" ]; then
      bad "$op: broker secret is IDENTICAL to ${prev}'s — one leaked credential would register both"
    fi
  done
  seen_ops="$seen_ops $OP"

  # 4. the allow-listed callback host is this operator's own issuer host
  cb=$(val "$BROKER_ENV" "KIOSK_PROVE_${OP}_CALLBACK_HOST")
  iss=$(val "$f" KIOSK_ISSUER)
  ih=$(echo "$iss" | sed -E 's|^[a-zA-Z]+://||; s|/.*$||; s|:[0-9]+$||')
  if [ -z "$cb" ]; then
    bad "$op: broker has no KIOSK_PROVE_${OP}_CALLBACK_HOST — the SSRF guard refuses every callback"
  elif [ "$cb" = "$ih" ]; then
    ok "$op: callback host $cb matches its KIOSK_ISSUER host"
  else
    bad "$op: callback host $cb != KIOSK_ISSUER host $ih"
  fi

  # 5. the pinned broker public key — what create_order verifies the attestation with
  fp=$(val "$f" KIOSK_PROVE_PUBLIC_KEY_PEM | spki)
  if [ -z "$fp" ]; then
    bad "$op: KIOSK_PROVE_PUBLIC_KEY_PEM unset or unparseable — create_order cannot verify an attestation"
  elif [ -n "$broker_fp" ] && [ "$fp" = "$broker_fp" ]; then
    ok "$op: pinned broker key spki-sha256=$fp matches what the broker signs with"
  else
    bad "$op: pinned broker key spki-sha256=$fp does not match the broker's $broker_fp"
  fi

  # 6. both sides agree on WHICH broker
  for v in KIOSK_PROVE_ISSUER KIOSK_PROVE_BROKER_URL; do
    [ -n "$(val "$f" "$v")" ] && ok "$op: $v=$(val "$f" "$v")" || bad "$op: $v unset"
  done
  echo
done

if [ "$fail" = 0 ]; then
  echo "== KYC pairing OK — restart the operator units if anything above was renamed =="
else
  echo "== KYC pairing INCOMPLETE — see the FAIL lines above =="
fi
exit $fail
