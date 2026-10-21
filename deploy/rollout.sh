#!/usr/bin/env bash
# Write /etc/kiosk-demo/<unit>.env for the eight demo units from this checkout's
# deploy/env/<unit>.env.example. It is idempotent.
#
#   deploy/rollout.sh [user@host]     # host defaults to $KIOSK_DEPLOY_HOST
#
# From a checkout it sends itself to the box over ssh and runs there as root
# with `--on-box`; CI runs it with `--on-box` against a scratch directory.
#
# The template is the declaration: names, order, comments and every value this
# repository decides. Only a REPLACE_* value is a slot — kept if the box already
# has it, minted if not. The four somebody else holds (the DB passwords, Stripe,
# the locks' signing key, the broker's identity) are NAMED instead and that unit
# is left alone: a blank secret boots an app that fails closed and silently. Put
# one in its own file by hand and re-run.
#
# It touches no service, no database and no Caddy: restart what it reports.
# Run it BEFORE pushing prod-demo a tree that adds an env name: the push migrates
# with these files, and an app missing a name it requires cannot boot to migrate.
set -euo pipefail

if [ "${1:-}" != --on-box ]; then
  host=${1:-${KIOSK_DEPLOY_HOST:-}}
  [ -n "$host" ] || { echo "rollout.sh: no host. Pass user@host, or set KIOSK_DEPLOY_HOST." >&2; exit 2; }
  exec ssh "$host" 'sudo bash -s -- --on-box' <"$0"
fi
shift

OWNER=${KIOSK_OWNER:-ubuntu:ubuntu}   # the push-to-deploy hook sources every one of these
MODE=0640
DIR=${KIOSK_ENV_DIR:-/etc/kiosk-demo}
SRC=${KIOSK_SRC:-/srv/kiosk}/deploy/env
UNITS=(atablefor getgrocery hoteling philslist skooti stylish tudu prove)  # broker last: it reads the operators'

# shellcheck disable=SC2016  # this is an awk program; nothing in it is shell
ed25519() { # stdin is a private PEM; true when it is an Ed25519 key, the one type Kiosk signs with
  openssl pkey -noout -text 2>/dev/null | grep -q '^ED25519 Private-Key'
}

value() {   # value <file> <KEY> — the whole right-hand side, a multi-line quoted PEM included
  awk -v k="$2=" 'index($0,k)==1{v=substr($0,length(k)+1);print v
                  if(v~/^"/&&v!~/"$/){q=1;next}exit} q{print;if(/"$/)exit}' "$1" 2>/dev/null || true
}

render() {  # render <unit> — stdout is the file that unit should have
  local live=$DIR/$1.env line key val o
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in [A-Za-z_]*=*REPLACE_*) key=${line%%=*} ;; *) printf '%s\n' "$line"; continue ;; esac
    case $1/$key in
      prove/KIOSK_PROVE_*_SECRET)   # one secret, two names: the operator's own copy is the source
        o=${key#KIOSK_PROVE_}; o=${o%_SECRET}; val=$(value "$DIR/${o,,}.env" KIOSK_PROVE_INTAKE_SECRET) ;;
      */KIOSK_PROVE_PUBLIC_KEY_PEM) # the public half of the broker's own key, when it is an Ed25519 key
        o=$(value "$DIR/prove.env" PROVE_KEY_PEM | tr -d '"')
        val=; ! printf '%s\n' "$o" | ed25519 || val=\"$(printf '%s\n' "$o" | openssl pkey -pubout)\" ;;
      *) val=$(value "$live" "$key")
         case $key in   # a key that is not an Ed25519 key is a slot to fill again
           KIOSK_SIGNING_KEY_B64) printf '%s' "$val" | openssl base64 -d -A 2>/dev/null | ed25519 || val= ;;
           PROVE_KEY_PEM)         printf '%s\n' "$val" | tr -d '"' | ed25519 || val= ;;
         esac
         [ -n "$val" ] || case $key in   # nothing off this box holds the other half of these
           SECRET_KEY_BASE)                            val=$(openssl rand -hex 64) ;;
           KIOSK_POW_SECRET|KIOSK_PROVE_INTAKE_SECRET) val=$(openssl rand -hex 32) ;;
           KIOSK_SIGNING_KEY_B64)                      val=$(openssl genpkey -algorithm ed25519 | openssl base64 -A) ;;
         esac ;;
    esac
    [ -n "$val" ] || { echo "MISSING $1 $key" >&2; return 1; }
    printf '%s=%s\n' "$key" "$val"
  done <"$SRC/${1/prove/kyc-demo}.env.example"   # the broker unit is `prove`, its template `kyc-demo`
}

[ $# -eq 0 ] || { echo "rollout.sh --on-box takes no other argument" >&2; exit 2; }

new=$(mktemp); trap 'rm -f "$new"' EXIT; fail=0
for u in "${UNITS[@]}"; do
  live=$DIR/$u.env
  render "$u" >"$new" || { fail=1; continue; }
  now=$(stat -c '%U:%G %a' "$live" 2>/dev/null || stat -f '%Su:%Sg %Lp' "$live" 2>/dev/null || true)
  if cmp -s "$new" "$live" && [ "$now" = "$OWNER ${MODE#0}" ]; then echo "ok     $u"; continue; fi
  [ ! -e "$live" ] || cp -p "$live" "$live.bak-$(date +%F)"
  cat "$new" >"$live"
  chown "$OWNER" "$live"
  chmod "$MODE" "$live"
  echo "wrote  $u — systemctl restart kiosk-demo@$u"
done
exit $fail
