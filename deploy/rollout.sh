#!/usr/bin/env bash
# rollout.sh — writes /etc/kiosk-demo/*.env from the templates in this
# repository. Run it ON THE BOX.
#
#   ssh <deploy-user>@<box> 'sudo bash -s' -- --check   < deploy/rollout.sh
#   ssh <deploy-user>@<box> 'sudo bash -s' -- --apply   < deploy/rollout.sh
#
# ── THE DECLARATION ─────────────────────────────────────────────────────────
#
# `deploy/env/<name>.env.example`, in the checkout at $KIOSK_REPO (default
# /srv/kiosk), carries the variable set, the order, the comments and every value
# this repository decides — port, issuer, database name, login role, toll
# difficulty, toll mode, broker URL, callback host. This script renders that
# template onto the box and fills only its `REPLACE_*` slots. TO CHANGE THE
# FLEET'S CONFIGURATION, EDIT THE TEMPLATE AND RE-RUN THIS.
#
# The declaration is the checkout ON THE BOX, not `main`: an env file belongs to
# the code that reads it, and /srv/kiosk is the code the units are running. So
# deploy first if the question you mean is «does the fleet match head».
#
# A unit is named after its template, with one exception: `kyc-demo.env.example`
# configures the unit `prove`, whose gem directory is `kiosk-demo-prove` while
# it serves kyc.demo.kiosk.tech.
#
# ── WHERE SECRETS COME FROM, AND WHAT HAPPENS ON A WIPED BOX ────────────────
#
# NO SECRET IS IN THIS FILE AND NO SECRET IS EVER PRINTED. A value is resolved
# from, in order:
#
#   1. the VAULT — an operator-supplied file of `<UNIT>__<VARIABLE>=value`
#      lines, default /etc/kiosk-demo/secrets.env, override with --secrets.
#   2. the value already in /etc/kiosk-demo/<unit>.env, so a re-run on a healthy
#      box ROTATES NOTHING.
#
# There is no third source and no prompt: the script arrives over `bash -s`, so
# its stdin is the script and there is nobody to ask.
#
# ON A WIPED BOX both sources are empty for every secret:
#
#   * --apply alone REFUSES. It names every unresolvable variable, per unit, and
#     writes NOTHING — not one file, not one blank. Exit 2. A BLANK IS WORSE
#     THAN A REFUSAL: an app that boots with an empty secret fails closed and
#     silently.
#   * --apply --generate-missing mints the values nothing outside
#     /etc/kiosk-demo holds the other half of — SECRET_KEY_BASE,
#     KIOSK_POW_SECRET, KIOSK_SIGNING_KEY_B64 and the shared KYC intake secret —
#     and prints their names. Minting a signing or session key logs every
#     assistant out: free on a wiped box, not on one whose database survived.
#     It still REFUSES, by name and with the command that produces each, the
#     four whose other half is somewhere else:
#       KIOSK_<APP>_DB_PASSWORD       — Postgres holds it (deploy/postgres-init.sql)
#       STRIPE_SECRET_KEY             — Stripe issues it
#       KIOSK_UNLOCK_SIGNING_KEY_PEM  — its public half is flashed into the locks
#       PROVE_KEY_PEM                 — a new broker identity invalidates every
#                                       attestation already issued
#
# Each operator's `KIOSK_PROVE_PUBLIC_KEY_PEM` is DERIVED from the broker's
# `PROVE_KEY_PEM` on this same box, so the pinned key cannot disagree with the
# key the broker signs with. A vault entry for it is REFUSED.
#
# The KYC intake secret is ONE value under TWO names — the operator reads
# `KIOSK_PROVE_INTAKE_SECRET`, the broker a per-operator
# `KIOSK_PROVE_<OP>_SECRET` — so the vault names it once, as
# `KYC_INTAKE_SECRET_<OP>`, and this script writes both sides from it. A vault
# entry that would set one side alone is REFUSED by name, --check pairs the two
# sides BY VALUE on every run, and a box where both sides are live and DISAGREE
# is refused rather than reconciled.
#
# ── WHO READS AN ENV FILE ───────────────────────────────────────────────────
#
# systemd hands each file to its unit through `EnvironmentFile=`, which it reads
# as root, and /srv/kiosk.git/hooks/post-receive SOURCES every one of them as
# the account a push arrives as. That account is the one that needs the read and
# nobody else does, so --apply gives each file to it at mode 0640 and --check
# names any file that is not there yet. `--hook-account` states the account;
# otherwise it is the owner of the hook file, reported as an INFERENCE; with
# neither, the run says the account is undetermined and leaves owner and mode
# alone.
#
# ── TWO KINDS OF DISAGREEMENT, AND ONLY ONE IS RED ──────────────────────────
#
# CONFIG — a declared variable missing, empty or disagreeing with the tree, a
#   retired name still assigned, a KYC pair that does not pair, a file the
#   deploy hook cannot read. `--check` exits 1; `--apply` corrects it.
# FORM — the file is not byte-identical to what `--apply` would write: order,
#   comments, a variable nobody declares. Never red, so a first run against a
#   hand-maintained fleet answers the question that matters rather than a
#   cosmetic one. `--check --strict` reddens on it too; one `--apply` drains it.
#
# ── WHAT IT DOES NOT DO ─────────────────────────────────────────────────────
#
# IT DOES NOT TOUCH CADDY. /etc/caddy/Caddyfile is `deploy/deploy-caddy.sh`'s.
# IT DOES NOT RESTART ANYTHING — it prints the `systemctl restart` line for each
# unit whose file it changed and stops there.
# IT DOES NOT TOUCH POSTGRES, run migrations, or seed; those belong to the
# push-to-deploy hook (deploy/CHECKLIST.md §7).
# IT DOES NOT READ ANYTHING OVER THE NETWORK.
#
# ── WHAT IT LEAVES BEHIND ───────────────────────────────────────────────────
#
# For every file it modifies, a dated sibling `<file>.bak-YYYY-MM-DD`, made with
# `cp -p`, once per day per file and never overwritten. Nothing else: no state
# file, no lock, no log. Every mode prints a verdict line and exits 0 (in
# agreement), 1 (CONFIG drift) or 2 (refused: something could not be resolved,
# parsed, or is not allowed).
#
# `--self-test` builds its own throwaway tree under `mktemp -d` and proves the
# parser, idempotence, drift correction, the refusal on a missing secret, the
# KYC pairing both ways, the access rule and that no secret reaches the output.
# It touches no host and no /etc, and runs in CI.

set -uo pipefail

VERSION_LINE="deploy/rollout.sh"
STAMP=$(date -u +%Y-%m-%d)

# ── The template values that are SLOTS, and what each one is ────────────────
#
# Every `REPLACE_*` value in every shipped template must appear here. A slot
# nobody classified is REFUSED rather than guessed at.
#
#   generate  — mintable here: nothing outside /etc/kiosk-demo holds its other half
#   external  — must be supplied: something off this box holds the other half
#   paired    — the KYC intake secret; one value, two files, two names
#   derived   — computed from another resolved value
classify_slot() {
  case "$1" in
    SECRET_KEY_BASE|KIOSK_POW_SECRET|KIOSK_SIGNING_KEY_B64) echo generate ;;
    KIOSK_PROVE_INTAKE_SECRET|KIOSK_PROVE_*_SECRET)         echo paired ;;
    KIOSK_PROVE_PUBLIC_KEY_PEM)                             echo derived ;;
    *_DB_PASSWORD|STRIPE_SECRET_KEY|KIOSK_UNLOCK_SIGNING_KEY_PEM|PROVE_KEY_PEM) echo external ;;
    *) echo unclassified ;;
  esac
}

# How to obtain an `external` value, printed when one is missing. No value here
# is a secret; each is the command deploy/CHECKLIST.md already names.
how_to_get() {
  case "$1" in
    *_DB_PASSWORD) echo "the password deploy/postgres-init.sql was given for this role (-v <xx>_pw=); Postgres holds the other half" ;;
    STRIPE_SECRET_KEY) echo "a Stripe TEST-mode secret key, sk_test_… , from the Stripe dashboard" ;;
    KIOSK_UNLOCK_SIGNING_KEY_PEM) echo "openssl genpkey -algorithm ed25519   — WARNING: every provisioned lock carries the PUBLIC half of the old key and must be reflashed" ;;
    PROVE_KEY_PEM) echo "openssl genrsa 2048   — WARNING: a new broker identity invalidates every attestation already issued" ;;
    *) echo "an operator-supplied value" ;;
  esac
}

# ── Names that must NOT be assigned, and why ────────────────────────────────
#
# Retired-ness is PER UNIT, because one of these names is retired in one demo
# and load-bearing in another: `KIOSK_POW_DEMO` is a legacy single-mode alias
# wherever `KIOSK_POW_MODE` is the selector, and it is getgrocery's own and only
# toll selector. So the question is never «is this name dead», it is «does this
# unit's template declare it».
retired_reason() {   # retired_reason <unit> <name> ; empty output = not retired
  local unit=$1 name=$2
  case "$name" in
    KIOSK_POW_REGISTER_DEMO)
      echo "read by nothing since registration PoW became unconditional" ;;
    KIOSK_POW_DEMO|KIOSK_POW_REPUTATION_DEMO|KIOSK_POW_BACKOFF_DEMO)
      if [ "${TPL_HAS_POW_MODE[$unit]:-0}" = 1 ]; then
        echo "a legacy single-mode alias; this unit selects its policy with KIOSK_POW_MODE, and two aliases at once refuse at boot"
      fi ;;
    KIOSK_PROVE_INTAKE_SECRET)
      : ;;                                   # the LIVE operator-side name
    KIOSK_PROVE_*_SECRET)
      # The per-operator spelling belongs to the BROKER, never to an operator.
      if [ "${IS_OPERATOR[$unit]:-0}" = 1 ]; then
        echo "the operator side reads KIOSK_PROVE_INTAKE_SECRET; nothing reads this spelling"
      fi ;;
  esac
}

# ── Parsing an env file without executing it ────────────────────────────────
#
# This script REWRITES what it reads, so a file it cannot parse is refused
# rather than sourced. The grammar it accepts is the grammar the templates are
# written in — `NAME=value`, an optional `export`, single or double quotes, a
# double-quoted value spanning lines (which is how a PEM is carried), `#`
# comments and blank lines. Anything else fails with its line number, and
# nothing is written.
#
# Values come back one per line as `NAME<TAB>escaped`, where a backslash is
# doubled and a newline is `\n`, so `printf '%b'` inverts it exactly.
# shellcheck disable=SC2016  # this IS an awk program; nothing here is shell
PARSER='
function emit(n, v) { gsub(/\\/, "\\\\", v); gsub(/\n/, "\\n", v); printf "%s\t%s\n", n, v }
BEGIN { inq = 0 }
{
  line = $0
  if (inq) {
    # Scan for the closing quote, honouring backslash escapes in "..."
    i = 1; out = ""
    while (i <= length(line)) {
      c = substr(line, i, 1)
      if (q == "\"" && c == "\\" && i < length(line)) {
        n = substr(line, i + 1, 1)
        if (n == "\\" || n == "\"" || n == "$" || n == "`") { out = out n; i += 2; continue }
        out = out c; i += 1; continue
      }
      if (c == q) { val = val "\n" out; emit(name, val); inq = 0; if (substr(line, i + 1) ~ /[^ \t]/) { bad = NR; exit 1 } ; next }
      out = out c; i += 1
    }
    val = val "\n" out
    next
  }
  if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) next
  if (line !~ /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/) { bad = NR; exit 1 }
  sub(/^[ \t]*/, "", line); sub(/^export[ \t]+/, "", line)
  eq = index(line, "=")
  name = substr(line, 1, eq - 1)
  rest = substr(line, eq + 1)
  if (substr(rest, 1, 1) == "\"" || substr(rest, 1, 1) == "'"'"'") {
    q = substr(rest, 1, 1); line = substr(rest, 2); val = ""
    i = 1; out = ""
    while (i <= length(line)) {
      c = substr(line, i, 1)
      if (q == "\"" && c == "\\" && i < length(line)) {
        n = substr(line, i + 1, 1)
        if (n == "\\" || n == "\"" || n == "$" || n == "`") { out = out n; i += 2; continue }
        out = out c; i += 1; continue
      }
      if (c == q) { emit(name, out); if (substr(line, i + 1) ~ /[^ \t]/) { bad = NR; exit 1 } ; next2 = 1; break }
      out = out c; i += 1
    }
    if (next2) { next2 = 0; next }
    inq = 1; val = out
    next
  }
  # A bare value may not carry anything the shell would act on.
  if (rest ~ /[ \t"'"'"'`$\\]/) { bad = NR; exit 1 }
  emit(name, rest)
}
END { if (inq) { print "UNTERMINATED" > "/dev/stderr"; exit 1 } }
'

parse_file() {   # parse_file <path> ; NAME<TAB>escaped on stdout, exit 1 on a refusal
  awk "$PARSER" "$1"
}

# ── Rendering a value back into a file ──────────────────────────────────────
render_value() {   # render_value <value> ; prints the right-hand side
  local v=$1
  case "$v" in
    "") printf '""' ; return ;;
  esac
  # Quote unless every character is one the shell would leave alone. A value
  # spanning lines always quotes: `grep` is line-based and would not see it.
  if printf '%s' "$v" | LC_ALL=C grep -q '[^A-Za-z0-9._:/@+=,%^~-]' || [ "${v%$'\n'*}" != "$v" ]; then
    local e=$v
    e=${e//\\/\\\\}
    e=${e//\"/\\\"}
    e=${e//\$/\\\$}
    e=${e//\`/\\\`}
    printf '"%s"' "$e"
  else
    printf '%s' "$v"
  fi
}

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
rollout.sh — declare the fleet's /etc/kiosk-demo/*.env from deploy/env/*.env.example

  --check                report agreement or drift; change nothing; exit 1 on CONFIG drift
  --check --strict       also exit 1 when a file is not byte-identical to what --apply writes
  --apply                write every unit's env file; back up what it changes
  --apply --generate-missing
                         additionally mint the secrets nothing off this box can hold
  --self-test            prove this script, in a throwaway tree; touches no host

  --secrets FILE         the vault (default: <env-dir>/secrets.env)
  --hook-account USER    the account the push-to-deploy hook runs as; --apply gives every
                         env file to it at 0640. Inferred from who owns the hook file when
                         it is not given
  --repo DIR             the checkout that declares the configuration (default: $KIOSK_REPO or /srv/kiosk)
  --root DIR             treat DIR as / — the env directory becomes DIR/etc/kiosk-demo

exit 0 in agreement · 1 CONFIG drift · 2 refused (unresolvable, unparseable, not allowed)
USAGE
}

MODE=""
STRICT=0
GENERATE=0
ROOT=""
SECRETS=""
HOOK_ACCOUNT_ARG=""

# WHICH CHECKOUT DECLARES THE CONFIGURATION. On the box it is /srv/kiosk, which
# is what `kiosk-demo@.service` and `demo-reset.sh` hardcode and what this
# script arrives beside when it travels over `bash -s`. When it is run AS A FILE
# out of a checkout — CI, --self-test, a workstation dry run — the checkout it
# was run from is the honest answer, so it takes precedence over the hardcoded
# path and is still overridable by --repo or KIOSK_REPO.
SELF_PATH=${BASH_SOURCE[0]:-$0}
SANDBOX=""
REPO_DEFAULT=/srv/kiosk
if [ -r "$SELF_PATH" ]; then
  _d=$(cd "$(dirname "$SELF_PATH")/.." 2>/dev/null && pwd)
  [ -n "$_d" ] && [ -d "$_d/deploy/env" ] && REPO_DEFAULT=$_d
fi
REPO=${KIOSK_REPO:-$REPO_DEFAULT}

while [ $# -gt 0 ]; do
  case "$1" in
    --check)            MODE=check ;;
    --apply)            MODE=apply ;;
    --self-test)        MODE=selftest ;;
    --strict)           STRICT=1 ;;
    --generate-missing) GENERATE=1 ;;
    --secrets)          SECRETS=${2:-}; shift ;;
--hook-account)     HOOK_ACCOUNT_ARG=${2:-}; shift ;;
    --repo)             REPO=${2:-}; shift ;;
    --root)             ROOT=${2:-}; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "rollout.sh: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ENVDIR="${ROOT}/etc/kiosk-demo"
[ -n "$SECRETS" ] || SECRETS="$ENVDIR/secrets.env"

# A --hook-account naming nothing is a typo, and it is refused before anything
# is written rather than where it is used.
HOOK_ACCOUNT_UID=""
if [ -n "$HOOK_ACCOUNT_ARG" ]; then
  case "$HOOK_ACCOUNT_ARG" in
    *[!0-9]*)
      HOOK_ACCOUNT_UID=$(id -u "$HOOK_ACCOUNT_ARG" 2>/dev/null)
      if [ -z "$HOOK_ACCOUNT_UID" ]; then
        echo "REFUSED  --hook-account $HOOK_ACCOUNT_ARG: this box has no such account." >&2
        exit 2
      fi ;;
    *) HOOK_ACCOUNT_UID=$HOOK_ACCOUNT_ARG ;;
  esac
fi

# ── State, filled by load_declaration ───────────────────────────────────────
declare -A TPL_FOR_UNIT=()      # unit -> template path
declare -A TPL_HAS_POW_MODE=()  # unit -> 1 when its template selects with KIOSK_POW_MODE
declare -A IS_OPERATOR=()       # unit -> 1 when its template declares KIOSK_ISSUER
declare -A TPL_VALUE=()         # "unit|NAME" -> template value (unescaped)
declare -A TPL_NAMES=()         # unit -> newline-joined declared names, in order
declare -A BOX_VALUE=()         # "unit|NAME" -> value currently on the box
declare -A BOX_NAMES=()         # unit -> newline-joined names currently on the box
declare -A BOX_PRESENT=()       # unit -> 1 when the file exists
declare -A VAULT=()             # vault key -> value
declare -A DESIRED=()           # "unit|NAME" -> the value that must be written
declare -A MINTED=()            # "unit|NAME" -> 1
KYC_OPS=""                      # operator units that pin the broker
BROKER_UNIT=""

unesc() { printf '%b' "$1"; }

# A value the box really carries: assigned, non-empty, and not the template's
# own REPLACE_ placeholder copied across by hand.
live_value() {   # live_value <unit> <NAME>
  local v=${BOX_VALUE["$1|$2"]:-}
  [ -n "$v" ] || return 0
  case "$v" in *REPLACE_*) return 0 ;; esac
  printf '%s' "$v"
}

load_declaration() {
  local tdir="$REPO/deploy/env" t base unit line name esc
  if [ ! -d "$tdir" ]; then
    echo "REFUSED  no declaration: $tdir is not a directory (set --repo or KIOSK_REPO to the checkout)" >&2
    exit 2
  fi
  local found=0
  for t in "$tdir"/*.env.example; do
    [ -f "$t" ] || continue
    found=1
    base=${t##*/}; base=${base%.env.example}
    # The one documented name exception: kyc-demo.env.example configures the
    # unit `prove` (kiosk-demo@.service's header carries the reason).
    unit=$base
    [ "$base" = "kyc-demo" ] && unit=prove
    TPL_FOR_UNIT[$unit]=$t
    TPL_NAMES[$unit]=""
    local parsed
    parsed=$(parse_file "$t"); local rc=$?
    if [ $rc -ne 0 ]; then
      echo "REFUSED  cannot parse the declaration $t — this script rewrites what it reads" >&2
      exit 2
    fi
    while IFS=$'\t' read -r name esc; do
      [ -n "$name" ] || continue
      TPL_VALUE["$unit|$name"]=$(unesc "$esc")
      TPL_NAMES[$unit]="${TPL_NAMES[$unit]}$name"$'\n'
      [ "$name" = "KIOSK_POW_MODE" ] && TPL_HAS_POW_MODE[$unit]=1
      [ "$name" = "KIOSK_ISSUER" ] && IS_OPERATOR[$unit]=1
      [ "$name" = "PROVE_KEY_PEM" ] && BROKER_UNIT=$unit
    done <<<"$parsed"
  done
  if [ "$found" = 0 ]; then
    echo "REFUSED  no *.env.example under $tdir — the declaration is empty, which is not an all-clear" >&2
    exit 2
  fi
  # Which operators pin the broker: the ones whose template carries the
  # role-named intake secret. Derived, never listed.
  local u
  for u in $(printf '%s\n' "${!TPL_FOR_UNIT[@]}" | sort); do
    [ -n "${TPL_VALUE["$u|KIOSK_PROVE_INTAKE_SECRET"]+x}" ] && KYC_OPS="$KYC_OPS $u"
  done
}

load_box() {
  local unit f parsed name esc rc
  for unit in $(printf '%s\n' "${!TPL_FOR_UNIT[@]}" | sort); do
    f="$ENVDIR/$unit.env"
    BOX_NAMES[$unit]=""
    if [ ! -f "$f" ]; then BOX_PRESENT[$unit]=0; continue; fi
    BOX_PRESENT[$unit]=1
    parsed=$(parse_file "$f"); rc=$?
    if [ $rc -ne 0 ]; then
      echo "REFUSED  cannot parse $f — refusing to rewrite a file whose grammar this script does not know" >&2
      exit 2
    fi
    while IFS=$'\t' read -r name esc; do
      [ -n "$name" ] || continue
      BOX_VALUE["$unit|$name"]=$(unesc "$esc")
      BOX_NAMES[$unit]="${BOX_NAMES[$unit]}$name"$'\n'
    done <<<"$parsed"
  done
}

load_vault() {
  [ -f "$SECRETS" ] || return 0
  local parsed name esc rc
  parsed=$(parse_file "$SECRETS"); rc=$?
  if [ $rc -ne 0 ]; then
    echo "REFUSED  cannot parse the vault $SECRETS" >&2
    exit 2
  fi
  while IFS=$'\t' read -r name esc; do
    [ -n "$name" ] || continue
    VAULT[$name]=$(unesc "$esc")
  done <<<"$parsed"
}

# A vault may not set ONE side of a shared secret. Refusing is the point: the
# pair is the thing that went wrong, so the script offers no spelling that can
# express half of it.
check_vault_forbidden() {
  local k op OP bad=0
  for k in $(printf '%s\n' "${!VAULT[@]}" | sort); do
    case "$k" in
      *__KIOSK_PROVE_INTAKE_SECRET)
        op=${k%%__*}
        echo "REFUSED  vault key $k would set ONE side of a shared KYC secret." >&2
        echo "         Use KYC_INTAKE_SECRET_$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]') — this script writes both sides from it." >&2
        bad=1 ;;
      *__KIOSK_PROVE_*_SECRET)
        OP=${k#*__KIOSK_PROVE_}; OP=${OP%_SECRET}
        echo "REFUSED  vault key $k would set ONE side of a shared KYC secret." >&2
        echo "         Use KYC_INTAKE_SECRET_$OP — this script writes both sides from it." >&2
        bad=1 ;;
      *__KIOSK_PROVE_PUBLIC_KEY_PEM)
        echo "REFUSED  vault key $k sets a DERIVED value." >&2
        echo "         The pinned broker key is computed from the broker's PROVE_KEY_PEM on this box, so it cannot disagree with what the broker signs with." >&2
        bad=1 ;;
    esac
  done
  [ "$bad" = 0 ] || exit 2
}

# ── Resolving one slot ──────────────────────────────────────────────────────
mint() {   # mint <NAME> ; a value, on stdout, for a `generate` slot
  case "$1" in
    SECRET_KEY_BASE)       openssl rand -hex 64 ;;
    KIOSK_POW_SECRET)      openssl rand -hex 32 ;;
    KIOSK_SIGNING_KEY_B64) openssl genrsa 2048 2>/dev/null | openssl base64 -A ;;
    *) return 1 ;;
  esac
}

MISSING=""          # human-readable lines, printed together at the end
missing() { MISSING="${MISSING}    $1"$'\n'; }

resolve_all() {
  local unit name tv kind vaultkey op OP shared
  for unit in $(printf '%s\n' "${!TPL_FOR_UNIT[@]}" | sort); do
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      tv=${TPL_VALUE["$unit|$name"]}
      case "$tv" in
        *REPLACE_*) ;;                      # a slot — resolved below
        *) # Not a slot: the tree decides it, and the vault may override it
           vaultkey="$(printf '%s' "$unit" | tr '[:lower:]' '[:upper:]')__$name"
           if [ -n "${VAULT[$vaultkey]+x}" ]; then DESIRED["$unit|$name"]=${VAULT[$vaultkey]}
           else DESIRED["$unit|$name"]=$tv; fi
           continue ;;
      esac

      kind=$(classify_slot "$name")
      case "$kind" in
        unclassified)
          echo "REFUSED  $unit: the template slot $name is not classified in this script." >&2
          echo "         A new secret in deploy/env/ must be given a class here — generate, external, paired or derived — rather than guessed at." >&2
          exit 2 ;;
        paired|derived)
          continue ;;                       # handled after this loop
      esac

      vaultkey="$(printf '%s' "$unit" | tr '[:lower:]' '[:upper:]')__$name"
      if [ -n "${VAULT[$vaultkey]+x}" ] && [ -n "${VAULT[$vaultkey]}" ]; then
        DESIRED["$unit|$name"]=${VAULT[$vaultkey]}
      elif [ -n "${BOX_VALUE["$unit|$name"]+x}" ] && [ -n "${BOX_VALUE["$unit|$name"]}" ] &&
           [ "${BOX_VALUE["$unit|$name"]#*REPLACE_}" = "${BOX_VALUE["$unit|$name"]}" ]; then
        DESIRED["$unit|$name"]=${BOX_VALUE["$unit|$name"]}
      elif [ "$kind" = generate ] && [ "$GENERATE" = 1 ]; then
        DESIRED["$unit|$name"]=$(mint "$name")
        MINTED["$unit|$name"]=1
      elif [ "$kind" = generate ]; then
        missing "$unit: $name — not in the vault ($vaultkey) and not on the box. Mintable here: re-run with --generate-missing, or put it in the vault."
      else
        missing "$unit: $name — not in the vault ($vaultkey) and not on the box. NOT mintable here: $(how_to_get "$name")"
      fi
    done <<<"${TPL_NAMES[$unit]}"
  done

  # ── The KYC pair, both sides from one value ──────────────────────────────
  for op in $KYC_OPS; do
    OP=$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]')
    shared=""
    if [ -n "${VAULT[KYC_INTAKE_SECRET_$OP]+x}" ] && [ -n "${VAULT[KYC_INTAKE_SECRET_$OP]}" ]; then
      shared=${VAULT[KYC_INTAKE_SECRET_$OP]}
    else
      local bside="" oside=""
      if [ -n "$BROKER_UNIT" ]; then bside=$(live_value "$BROKER_UNIT" "KIOSK_PROVE_${OP}_SECRET"); fi
      oside=$(live_value "$op" "KIOSK_PROVE_INTAKE_SECRET")
      if [ -n "$bside" ] && [ -n "$oside" ] && [ "$bside" != "$oside" ]; then
        # BOTH sides are live and they DISAGREE. There is no correct guess here:
        # taking the broker's would silently re-key the operator and taking the
        # operator's would silently re-key every other operator's neighbour. The
        # script says so and stops.
        echo "REFUSED  $op: the two sides of the shared KYC intake secret are BOTH set and they DISAGREE." >&2
        echo "         $ENVDIR/$op.env KIOSK_PROVE_INTAKE_SECRET != $ENVDIR/${BROKER_UNIT:-prove}.env KIOSK_PROVE_${OP}_SECRET" >&2
        echo "         This script will not choose between two live secrets. Put the one you mean in the vault as KYC_INTAKE_SECRET_$OP and re-run." >&2
        exit 2
      fi
      if   [ -n "$bside" ]; then shared=$bside
      elif [ -n "$oside" ]; then shared=$oside
      fi
    fi
    if [ -z "$shared" ]; then
    if [ "$GENERATE" = 1 ]; then
      shared=$(openssl rand -hex 32)
      MINTED["$op|KIOSK_PROVE_INTAKE_SECRET"]=1
    else
      missing "$op + ${BROKER_UNIT:-prove}: the shared KYC intake secret — not in the vault (KYC_INTAKE_SECRET_$OP) and on neither side of the box. Mintable here: re-run with --generate-missing."
    fi
    fi
    if [ -n "$shared" ]; then
      DESIRED["$op|KIOSK_PROVE_INTAKE_SECRET"]=$shared
      [ -n "$BROKER_UNIT" ] && DESIRED["$BROKER_UNIT|KIOSK_PROVE_${OP}_SECRET"]=$shared
    fi
  done

  # ── The pinned broker key, derived from the broker's own private half ────
  if [ -n "$BROKER_UNIT" ]; then
    local priv pub
    priv=${DESIRED["$BROKER_UNIT|PROVE_KEY_PEM"]:-}
    if [ -n "$priv" ]; then
      pub=$(printf '%s\n' "$priv" | openssl pkey -pubout 2>/dev/null)
      if [ -z "$pub" ]; then
        echo "REFUSED  ${BROKER_UNIT}: PROVE_KEY_PEM does not parse as a private key, so the operators' pinned public half cannot be derived." >&2
        exit 2
      fi
      for op in $KYC_OPS; do DESIRED["$op|KIOSK_PROVE_PUBLIC_KEY_PEM"]=$pub; done
    else
      for op in $KYC_OPS; do
        missing "$op: KIOSK_PROVE_PUBLIC_KEY_PEM is DERIVED from ${BROKER_UNIT}'s PROVE_KEY_PEM, which is itself unresolved (above)."
      done
    fi
  fi
}

# ── Rendering one unit's file ───────────────────────────────────────────────
render_unit() {   # render_unit <unit> ; the whole file on stdout
  local unit=$1 tpl=${TPL_FOR_UNIT[$1]} name line rest inq=0 q=""
  echo "# WRITTEN BY $VERSION_LINE FROM ${tpl##*/} — edit the template in the"
  echo "# repository and re-run; a hand edit here is drift this script will undo."
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inq" = 1 ]; then
      case "$line" in *"$q"*) inq=0 ;; esac
      continue                       # the template's old value; already replaced
    fi
    local bare=${line#"${line%%[![:space:]]*}"}
    case "$bare" in
      ""|\#*) printf '%s\n' "$line"; continue ;;
    esac
    if printf '%s' "$bare" | LC_ALL=C grep -qE '^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*='; then
      name=${bare#export }; name=${name%%=*}
      rest=${bare#*=}
      case "$rest" in
        \"*) case "${rest#\"}" in *\"*) : ;; *) inq=1; q='"' ;; esac ;;
        \'*) case "${rest#\'}" in *\'*) : ;; *) inq=1; q="'" ;; esac ;;
      esac
      printf '%s=%s\n' "$name" "$(render_value "${DESIRED["$unit|$name"]:-}")"
    else
      printf '%s\n' "$line"
    fi
  done <"$tpl"

  # Anything the box carries that nothing declares is PRESERVED, in a marked
  # block, rather than deleted: this script owns what the tree declares and is
  # not entitled to destroy what it has never heard of. A retired name is the
  # exception — it is named in the report and it does not come across.
  local extra="" n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case $'\n'"${TPL_NAMES[$unit]}" in *$'\n'"$n"$'\n'*) continue ;; esac
    [ -n "$(retired_reason "$unit" "$n")" ] && continue
    extra="${extra}$n=$(render_value "${BOX_VALUE["$unit|$n"]}")"$'\n'
  done <<<"${BOX_NAMES[$unit]:-}"
  if [ -n "$extra" ]; then
    echo ""
    echo "# ── UNDECLARED — present on this box, named by no template ──────────────"
    echo "# $VERSION_LINE preserves these and does not manage them. Either add the"
    echo "# variable to deploy/env/${tpl##*/} or delete it here."
    printf '%s' "$extra"
  fi
}

# ── The report ──────────────────────────────────────────────────────────────
CONFIG_DRIFT=0
FORM_DRIFT=0
CHANGED_UNITS=""

report_unit() {   # report_unit <unit> <rendered-file>
  local unit=$1 rendered=$2 name reason n cur want
  local f="$ENVDIR/$unit.env"
  local issues=0

  if [ "${BOX_PRESENT[$unit]:-0}" = 0 ]; then
    echo "    ABSENT  $f does not exist — every declared variable is missing"
    CONFIG_DRIFT=1
    return
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    want=${DESIRED["$unit|$name"]:-}
    if [ -z "${BOX_VALUE["$unit|$name"]+x}" ]; then
      echo "    MISSING $name"; issues=1; continue
    fi
    cur=${BOX_VALUE["$unit|$name"]}
    if [ -z "$cur" ]; then echo "    EMPTY   $name"; issues=1; continue; fi
    case "$cur" in *REPLACE_*) echo "    SLOT    $name still carries the template's placeholder"; issues=1; continue ;; esac
    if [ "$cur" != "$want" ]; then
      case "${TPL_VALUE["$unit|$name"]}" in
        *REPLACE_*) echo "    DIFFERS $name (a secret: value not shown)" ;;
        *)          echo "    DIFFERS $name — the tree declares \"$want\", the box has \"$cur\"" ;;
      esac
      issues=1
    fi
  done <<<"${TPL_NAMES[$unit]}"

  while IFS= read -r n; do
    [ -n "$n" ] || continue
    reason=$(retired_reason "$unit" "$n")
    if [ -n "$reason" ]; then echo "    RETIRED $n — $reason"; issues=1; continue; fi
    case $'\n'"${TPL_NAMES[$unit]}" in
      *$'\n'"$n"$'\n'*) ;;
      *) echo "    extra   $n — no template declares it (preserved, not managed)"; FORM_DRIFT=1 ;;
    esac
  done <<<"${BOX_NAMES[$unit]}"

  # In --apply the access is corrected as the file is written, and install_unit
  # says what it moved; there is nothing to report here first.
  if [ "$MODE" = check ] && ! access_ok "$f"; then
    echo "    ACCESS  $(access_have "$f") — the deploy hook needs $(access_want)"
    issues=1
  fi

  [ "$issues" = 1 ] && CONFIG_DRIFT=1

  if ! cmp -s "$rendered" "$f"; then
    [ "$issues" = 0 ] && echo "    FORM    every declared value agrees; the file differs in order or comments"
    FORM_DRIFT=1
    CHANGED_UNITS="$CHANGED_UNITS $unit"
  elif [ "$issues" = 0 ]; then
    echo "    ok      every declared variable is in place"
  fi
}

# ── Who reads an env file, and how this script sets it ──────────────────────
#
# The push-to-deploy hook SOURCES every /etc/kiosk-demo/*.env as the account a
# push arrives as, and that account is the only one that needs the read. So the
# target state is exact: owner the hook account, mode 0640. --apply sets it on
# every file it writes and corrects it on every file it does not.
ACCESS_MODE=0640
ACCESS_FAILED=0
HOOK_FILE=${ROOT}/srv/kiosk.git/hooks/post-receive
HOOK_UID=""
HOOK_GID=""
HOOK_FROM=""

# stat(1) is GNU on the box and BSD under --self-test on macOS, and they share
# no format flag. Printing nothing means «I do not know», never «all clear».
file_attrs() {   # file_attrs <path> ; "<uid> <gid> <4-digit octal mode>" on stdout
  local raw uid gid mode
  raw=$(stat -c '%u %g %a' "$1" 2>/dev/null) || raw=$(stat -f '%u %g %Lp' "$1" 2>/dev/null) || return 1
  read -r uid gid mode <<<"$raw"
  [ -n "$mode" ] || return 1
  printf '%s %s %04o\n' "$uid" "$gid" "$((8#$mode))"
}

uid_label() {   # uid_label <uid> ; "name (uid N)" or "uid N"
  local n
  n=$(id -un "$1" 2>/dev/null)
  if [ -n "$n" ]; then printf '%s (uid %s)' "$n" "$1"; else printf 'uid %s' "$1"; fi
}

# The account is the one thing here that cannot be measured from the files: git
# runs the hook as the ssh user, and nothing on disk records who that is.
resolve_hook_account() {   # sets HOOK_UID, HOOK_GID, HOOK_FROM; empty HOOK_UID = undetermined
  local a uid gid mode
  if [ -n "$HOOK_ACCOUNT_UID" ]; then
    HOOK_UID=$HOOK_ACCOUNT_UID
    HOOK_FROM="--hook-account $HOOK_ACCOUNT_ARG"
  elif [ -f "$HOOK_FILE" ] && a=$(file_attrs "$HOOK_FILE"); then
    read -r uid gid mode <<<"$a"
    HOOK_UID=$uid
    HOOK_FROM="INFERRED from who owns $HOOK_FILE"
  else
    return 0
  fi
  HOOK_GID=$(id -g "$HOOK_UID" 2>/dev/null) || HOOK_GID=""
}

# Right means: the hook account owns it and can read it, and nothing wider can.
# The group is only part of the answer when the mode actually grants it a read.
access_ok() {   # access_ok <path> ; 0 when nothing needs changing
  [ -n "$HOOK_UID" ] || return 0
  local a uid gid mode
  a=$(file_attrs "$1") || return 1   # cannot tell is not all clear
  read -r uid gid mode <<<"$a"
  [ "$uid" = "$HOOK_UID" ] || return 1
  [ $(( 8#$mode & 8#400 )) -ne 0 ] || return 1
  [ $(( 8#$mode & ~8#$ACCESS_MODE & 8#7777 )) -eq 0 ] || return 1
  [ $(( 8#$mode & 8#40 )) -eq 0 ] || [ -z "$HOOK_GID" ] || [ "$gid" = "$HOOK_GID" ]
}

access_want() { printf '%s%s %s' "$(uid_label "$HOOK_UID")" "${HOOK_GID:+:$HOOK_GID}" "$ACCESS_MODE"; }

access_have() {   # access_have <path>
  local a uid gid mode
  a=$(file_attrs "$1") || { printf 'attributes unreadable'; return; }
  read -r uid gid mode <<<"$a"
  printf '%s:%s %s' "$(uid_label "$uid")" "$gid" "$mode"
}

# chmod on a file you own always works; chown does not. A refusal leaves a file
# the deploy hook cannot read, so it is said out loud AND it fails the run — a
# step that fails and still reports success is the whole defect here.
set_access() {   # set_access <path>
  [ -n "$HOOK_UID" ] || return 0
  chmod "$ACCESS_MODE" "$1" || {
    echo "    WARNING    could not set mode $ACCESS_MODE on $1"
    ACCESS_FAILED=1
  }
  chown "$HOOK_UID${HOOK_GID:+:$HOOK_GID}" "$1" 2>/dev/null || {
    echo "    WARNING    $1 must belong to $(uid_label "$HOOK_UID") and chown was refused — re-run as root"
    ACCESS_FAILED=1
  }
}

fix_access() {   # fix_access <path> ; correct it, and say so only when it moves
  access_ok "$1" && return 0
  echo "    ACCESS     $1  $(access_have "$1") -> $(access_want)"
  set_access "$1"
}

# ── Writing ─────────────────────────────────────────────────────────────────
install_unit() {   # install_unit <unit> <rendered-file>
  local unit=$1 rendered=$2
  local f="$ENVDIR/$unit.env" bk="$ENVDIR/$unit.env.bak-$STAMP"
  if [ -f "$f" ] && cmp -s "$rendered" "$f"; then
    echo "    unchanged  $f"
    fix_access "$f"
    return
  fi
  if [ -f "$f" ] && [ ! -f "$bk" ]; then
    cp -p "$f" "$bk" || { echo "    FAILED     could not back $f up to $bk — nothing written" >&2; return 1; }
    echo "    backup     $bk"
  fi

  # When this run cannot say who must read the file, it does not get to decide:
  # the rename below replaces the inode, so the triple is read first and put
  # back after. With a known account, set_access decides instead.
  local keep=""
  [ -n "$HOOK_UID" ] || keep=$(file_attrs "$f") || keep=""

  ( umask 077; cat "$rendered" >"$f.rollout-new" ) || return 1
  mv "$f.rollout-new" "$f" || return 1
  if [ -n "$keep" ]; then
    local kuid kgid kmode
    read -r kuid kgid kmode <<<"$keep"
    if ! chmod "$kmode" "$f" 2>/dev/null || ! chown "$kuid:$kgid" "$f" 2>/dev/null; then
      echo "    WARNING    could not put $f back to $kuid:$kgid $kmode — a reader of it may have lost access"
      ACCESS_FAILED=1
    fi
  fi
  set_access "$f"
  echo "    WROTE      $f  ($(access_have "$f"))"
  CHANGED_UNITS="$CHANGED_UNITS $unit"
}

# ── The deploy hook, OBSERVED and never written ─────────────────────────────
#
# /srv/kiosk.git/hooks/post-receive is the only thing that turns a push into a
# deploy and it exists in no repository (deploy/CHECKLIST.md §7), so a wipe is
# something this run reports rather than something the next push discovers.
observe_hook() {
  local h=$HOOK_FILE
  echo "== push-to-deploy hook (observed, never written) =="
  if [ -f "$h" ]; then
    echo "    present  $h  $(wc -c <"$h" | tr -d ' ') bytes  sha256=$(openssl dgst -sha256 <"$h" | awk '{print $NF}')"
    [ -x "$h" ] || echo "    WARNING  it is not executable — a push will deploy nothing"
  else
    echo "    ABSENT   $h — nothing turns a push into a deploy, and this repository does not carry a copy"
    echo "             See deploy/CHECKLIST.md §7. Restore it from your own copy; do not re-clone /srv/kiosk.git."
  fi
  echo ""
}

main_run() {
  load_declaration
  load_vault
  check_vault_forbidden
  load_box
  resolve_all
  resolve_hook_account

  if [ -n "$MISSING" ]; then
    echo "== REFUSED — a value could not be resolved, so NOTHING was written ==" >&2
    printf '%s' "$MISSING" >&2
    echo "    A blank is worse than a refusal: an app that boots with an empty secret fails closed and silently." >&2
    echo "    Put the value in the vault ($SECRETS) as <UNIT>__<VARIABLE>=…, or see --help." >&2
    exit 2
  fi

  local tmp; tmp=$(mktemp -d) || exit 2
  trap 'rm -rf "$tmp"' EXIT

  echo "== $VERSION_LINE  ${MODE}  =="
  echo "   declaration : $REPO/deploy/env/*.env.example"
  echo "   env files   : $ENVDIR/<unit>.env"
  echo "   vault       : $SECRETS$([ -f "$SECRETS" ] || echo '  (absent — every secret came from the box)')"
  if [ -n "$HOOK_UID" ]; then
    echo "   deploy hook : runs as $(uid_label "$HOOK_UID") — $HOOK_FROM; env files are set to $(access_want)"
  else
    echo "   deploy hook : account UNDETERMINED — owner and mode are left as they are. Pass --hook-account <user>."
  fi
  echo ""

  local unit
  for unit in $(printf '%s\n' "${!TPL_FOR_UNIT[@]}" | sort); do
    render_unit "$unit" >"$tmp/$unit.env"
    echo "--- $unit  (${TPL_FOR_UNIT[$unit]##*/}, PORT=${DESIRED["$unit|PORT"]:-?}) ---"
    # NEVER pipe report_unit: a pipeline is a subshell, and the drift flags it
    # sets would be lost exactly where they decide the exit code.
    report_unit "$unit" "$tmp/$unit.env"
    if [ "$MODE" = apply ]; then
      install_unit "$unit" "$tmp/$unit.env" || exit 2
    fi
  done
  echo ""

  # The KYC pair, by value, on both sides — the one cross-file rule.
  echo "== KYC intake pairing (by value; no value is printed) =="
  local op OP a b
  for op in $KYC_OPS; do
    OP=$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]')
    if [ "$MODE" = check ]; then
      a=$(live_value "$op" "KIOSK_PROVE_INTAKE_SECRET")
      b=$(live_value "${BROKER_UNIT:-prove}" "KIOSK_PROVE_${OP}_SECRET")
    else
      a=${DESIRED["$op|KIOSK_PROVE_INTAKE_SECRET"]:-}
      b=${DESIRED["${BROKER_UNIT:-prove}|KIOSK_PROVE_${OP}_SECRET"]:-}
    fi
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
      echo "    PAIRED   $op.KIOSK_PROVE_INTAKE_SECRET = ${BROKER_UNIT:-prove}.KIOSK_PROVE_${OP}_SECRET"
    else
      echo "    BROKEN   $op — the two sides do not carry the same value"
      CONFIG_DRIFT=1
    fi
    [ -n "${MINTED["$op|KIOSK_PROVE_INTAKE_SECRET"]:-}" ] && echo "    MINTED   the shared secret for $op (both sides)"
  done
  echo ""

  if [ ${#MINTED[@]} -gt 0 ]; then
    echo "== MINTED THIS RUN (names only) =="
    local k
    for k in $(printf '%s\n' "${!MINTED[@]}" | sort); do echo "    ${k%%|*}: ${k#*|}"; done
    echo "    Minting a signing or session key logs every assistant out. On a wiped box that is free."
    echo ""
  fi

  observe_hook

  if [ "$MODE" = apply ] && [ -n "$CHANGED_UNITS" ]; then
    echo "== RESTART THESE, when you mean to — this script does not =="
    for unit in $(printf '%s' "$CHANGED_UNITS" | tr ' ' '\n' | LC_ALL=C grep . | sort -u); do
      echo "    systemctl restart kiosk-demo@$unit"
    done
    echo ""
  fi

  if [ "$MODE" = check ]; then
    if [ "$CONFIG_DRIFT" = 1 ]; then
      echo "== CONFIG DRIFT — the box is not what this tree declares. --apply fixes it =="; exit 1
    fi
    if [ "$FORM_DRIFT" = 1 ]; then
      echo "== configuration AGREES; form differs (order, comments, undeclared names). One --apply drains it =="
      [ "$STRICT" = 1 ] && exit 1
      exit 0
    fi
    echo "== the fleet's configuration is exactly what this tree declares =="; exit 0
  fi

  if [ "$ACCESS_FAILED" = 1 ]; then
    echo "== APPLIED, but an env file is still not readable by the deploy hook — read the WARNING lines =="; exit 1
  fi
  if [ "$CONFIG_DRIFT" = 1 ] && [ -z "$CHANGED_UNITS" ]; then
    echo "== APPLIED, but something above is still wrong — read the lines that are not 'ok' =="; exit 1
  fi
  echo "== APPLIED — re-run with --check to confirm =="; exit 0
}

# ── --self-test ─────────────────────────────────────────────────────────────
#
# Every arm builds its own tree under mktemp -d and points the script at it with
# --root and --repo. No /etc is read, no unit is restarted, no host is dialed.
selftest() {
  local fails=0
  SANDBOX=$(mktemp -d) || exit 2
  local sandbox=$SANDBOX
  trap 'rm -rf "$SANDBOX"' EXIT
  local self=$sandbox/rollout.sh
  cat "$SELF_PATH" >"$self"; chmod +x "$self"

  ok()   { echo "  ok    $*"; }
  bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }

  # ── A1: the parser round-trips the grammar the templates are written in ──
  local a1=$sandbox/a1.env
  {
    echo '# a comment'
    echo ''
    echo 'BARE=3001'
    echo 'export EXPORTED=yes'
    echo 'SINGLE='"'"'a b'"'"''
    # shellcheck disable=SC2016  # the literal `$y` is the fixture
    echo 'DOUBLE="x $y"'
    printf 'PEM="-----BEGIN-----\nline2\n-----END-----"\n'
  } >"$a1"
  local got
  got=$(awk "$PARSER" "$a1")
  if [ "$(printf '%s\n' "$got" | LC_ALL=C grep -c .)" = 5 ]; then ok "A1 parser reads all five assignments"
  else bad "A1 parser read $(printf '%s\n' "$got" | LC_ALL=C grep -c .) assignments, want 5"; fi
  if printf '%s\n' "$got" | LC_ALL=C grep -q '^PEM	-----BEGIN-----\\nline2\\n-----END-----$'; then
    ok "A1 a multi-line double-quoted value survives intact"
  else bad "A1 the multi-line value did not round-trip: $(printf '%s\n' "$got" | LC_ALL=C grep '^PEM')"; fi

  # ── A2: an unparseable line is REFUSED, never guessed at ─────────────────
  printf 'GOOD=1\nthis is not an assignment\n' >"$sandbox/a2.env"
  awk "$PARSER" "$sandbox/a2.env" >/dev/null 2>&1; local rc=$?
  if [ "$rc" != 0 ]; then ok "A2 a malformed line refuses (exit $rc)"; else bad "A2 a malformed line parsed cleanly"; fi

  # ── The shared fixture: a repo of templates and an empty box ─────────────
  local repo=$sandbox/repo root=$sandbox/root
  mkdir -p "$repo/deploy/env" "$root/etc/kiosk-demo"
  cat "$REPO/deploy/env"/*.env.example >/dev/null 2>&1 || { bad "the shipped templates are not readable at $REPO/deploy/env"; echo "check-rollout: $fails failure(s)"; return 1; }
  cp "$REPO/deploy/env"/*.env.example "$repo/deploy/env/"

  # ── A10 (vacuity): every REPLACE_ slot the tree ships is classified ──────
  local unclassified=0 t n v
  for t in "$repo/deploy/env"/*.env.example; do
    while IFS=$'\t' read -r n v; do
      case "$v" in *REPLACE_*) [ "$(classify_slot "$n")" = unclassified ] && { bad "A10 unclassified slot $n in ${t##*/}"; unclassified=1; } ;; esac
    done < <(awk "$PARSER" "$t")
  done
  [ "$unclassified" = 0 ] && ok "A10 every REPLACE_ slot in every shipped template has a class"
  local slots
  slots=$(for t in "$repo/deploy/env"/*.env.example; do awk "$PARSER" "$t"; done | LC_ALL=C grep -c 'REPLACE_')
  if [ "${slots:-0}" -ge 8 ]; then ok "A10 the vacuity arm saw $slots slots (a rule matching nothing is not coverage)"
  else bad "A10 only $slots slots found — the arm is vacuous"; fi

  # ── A5: a wiped box with an empty vault REFUSES and writes nothing ───────
  "$self" --apply --repo "$repo" --root "$root" >"$sandbox/a5.out" 2>&1; rc=$?
  if [ "$rc" = 2 ]; then ok "A5 a wiped box with no vault refuses (exit 2)"; else bad "A5 exit $rc, want 2"; fi
  local left
  left=$(find "$root/etc/kiosk-demo" -type f | tr '\n' ' ')
  if [ -z "$left" ]; then ok "A5 it wrote no file at all"; else bad "A5 it created $left"; fi
  if LC_ALL=C grep -q 'PROVE_KEY_PEM' "$sandbox/a5.out" && LC_ALL=C grep -q 'STRIPE_SECRET_KEY' "$sandbox/a5.out"; then
    ok "A5 it names the values it could not obtain"
  else bad "A5 the refusal does not name the missing values"; fi

  # ── The vault: the externals only. Everything else is minted. ────────────
  local vault=$sandbox/secrets.env sentinel=zzSECRETSENTINELzz
  local unit U
  : >"$vault"
  for t in "$repo/deploy/env"/*.env.example; do
    unit=${t##*/}; unit=${unit%.env.example}; [ "$unit" = kyc-demo ] && unit=prove
    U=$(printf '%s' "$unit" | tr '[:lower:]' '[:upper:]')
    while IFS=$'\t' read -r n v; do
      case "$v" in *REPLACE_*) ;; *) continue ;; esac
      case "$(classify_slot "$n")" in
        external)
          case "$n" in
            PROVE_KEY_PEM) printf '%s__%s="%s"\n' "$U" "$n" "$(openssl genrsa 2048 2>/dev/null)" >>"$vault" ;;
            KIOSK_UNLOCK_SIGNING_KEY_PEM) printf '%s__%s="%s"\n' "$U" "$n" "$(openssl genpkey -algorithm ed25519 2>/dev/null)" >>"$vault" ;;
            *) printf '%s__%s=%s-%s\n' "$U" "$n" "$sentinel" "$unit" >>"$vault" ;;
          esac ;;
      esac
    done < <(awk "$PARSER" "$t")
  done

  # ── A9: no secret ever reaches the output ────────────────────────────────
  "$self" --apply --generate-missing --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a9.out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A9 a wiped box with a vault applies cleanly (exit 0)"; else bad "A9 exit $rc, want 0"; cat "$sandbox/a9.out"; fi
  if LC_ALL=C grep -q "$sentinel" "$sandbox/a9.out"; then bad "A9 A SECRET REACHED THE OUTPUT"; else ok "A9 the sentinel secret appears nowhere in the output"; fi
  if LC_ALL=C grep -q "$sentinel" "$root/etc/kiosk-demo/getgrocery.env"; then ok "A9 the sentinel did reach the file (the arm is not vacuous)"
  else bad "A9 the sentinel never reached the file — the arm proves nothing"; fi

  # ── A3: idempotence ──────────────────────────────────────────────────────
  local before after
  before=$(cd "$root/etc/kiosk-demo" && openssl dgst -sha256 ./*.env | openssl dgst -sha256)
  "$self" --apply --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a3.out" 2>&1; rc=$?
  after=$(cd "$root/etc/kiosk-demo" && openssl dgst -sha256 ./*.env | openssl dgst -sha256)
  if [ "$before" = "$after" ]; then ok "A3 a second --apply leaves every file byte-identical"; else bad "A3 the second --apply changed something"; fi
  if LC_ALL=C grep -q 'unchanged' "$sandbox/a3.out"; then ok "A3 and it says so"; else bad "A3 it did not report the files as unchanged"; fi
  "$self" --check --strict --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a3c.out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A3 --check --strict is green on the tree it just wrote"; else bad "A3 --check --strict exit $rc, want 0"; cat "$sandbox/a3c.out"; fi

  # ── A4: drift in a declared non-secret is caught and corrected ───────────
  local f=$root/etc/kiosk-demo/tudu.env
  LC_ALL=C sed 's/^PORT=3007$/PORT=9999/' "$f" >"$f.mut" && mv "$f.mut" "$f"
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a4.out" 2>&1; rc=$?
  if [ "$rc" = 1 ]; then ok "A4 --check reddens on a changed declared value (exit 1)"; else bad "A4 --check exit $rc, want 1"; fi
  if LC_ALL=C grep -q 'DIFFERS PORT' "$sandbox/a4.out"; then ok "A4 and it names the variable"; else bad "A4 it did not name PORT"; fi
  "$self" --apply --repo "$repo" --root "$root" --secrets "$vault" >/dev/null 2>&1
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A4 --apply corrects it and --check goes green"; else bad "A4 still drifted after --apply (exit $rc)"; fi

  # ── A6: a retired name is red, and --apply removes it ────────────────────
  printf 'KIOSK_POW_REGISTER_DEMO=1\n' >>"$root/etc/kiosk-demo/stylish.env"
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a6.out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && LC_ALL=C grep -q 'RETIRED KIOSK_POW_REGISTER_DEMO' "$sandbox/a6.out"; then ok "A6 a retired name reddens and is named"
  else bad "A6 exit $rc; the retired name was not reported"; fi
  "$self" --apply --repo "$repo" --root "$root" --secrets "$vault" >/dev/null 2>&1
  if LC_ALL=C grep -q 'KIOSK_POW_REGISTER_DEMO' "$root/etc/kiosk-demo/stylish.env"; then bad "A6 --apply left the retired name in place"
  else ok "A6 --apply removed it"; fi

  # ── A7: the KYC pair — one side moved, and the repair ────────────────────
  local pf=$root/etc/kiosk-demo/prove.env
  local kept
  kept=$(awk "$PARSER" "$pf" | LC_ALL=C grep '^KIOSK_PROVE_GETGROCERY_SECRET	' | cut -f2)
  LC_ALL=C sed 's/^KIOSK_PROVE_GETGROCERY_SECRET=.*$/KIOSK_PROVE_GETGROCERY_SECRET=notthesamevalue/' "$pf" >"$pf.mut" && mv "$pf.mut" "$pf"
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a7.out" 2>&1; rc=$?
  if [ "$rc" = 2 ] && LC_ALL=C grep -q 'BOTH set and they DISAGREE' "$sandbox/a7.out"; then
    ok "A7 two live sides that disagree are REFUSED, not silently reconciled (exit 2)"
  else bad "A7 exit $rc; a disagreeing pair was not refused"; fi
  if LC_ALL=C grep -q 'KYC_INTAKE_SECRET_GETGROCERY' "$sandbox/a7.out"; then ok "A7 and it says which vault key settles it"
  else bad "A7 the refusal does not name the vault key"; fi
  # The operator says which value is real; both sides are then written from it.
  cp "$vault" "$sandbox/paired.env"
  printf 'KYC_INTAKE_SECRET_GETGROCERY=%s\n' "$kept" >>"$sandbox/paired.env"
  "$self" --apply --repo "$repo" --root "$root" --secrets "$sandbox/paired.env" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A7 --apply with the vault entry writes both sides from one value"; else bad "A7 the repair apply exited $rc"; fi
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a7b.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && LC_ALL=C grep -q 'PAIRED   getgrocery' "$sandbox/a7b.out"; then ok "A7 the pair is green afterwards, with no vault entry at all"
  else bad "A7 the pair was not repaired (exit $rc)"; fi

  # ── A8: a vault key that could set ONE side is refused ───────────────────
  cp "$vault" "$sandbox/half.env"
  printf 'GETGROCERY__KIOSK_PROVE_INTAKE_SECRET=anything\n' >>"$sandbox/half.env"
  "$self" --check --repo "$repo" --root "$root" --secrets "$sandbox/half.env" >"$sandbox/a8.out" 2>&1; rc=$?
  if [ "$rc" = 2 ] && LC_ALL=C grep -q 'ONE side of a shared KYC secret' "$sandbox/a8.out"; then ok "A8 a half-pair vault key is refused (exit 2)"
  else bad "A8 exit $rc; a half-pair vault key was accepted"; fi
  cp "$vault" "$sandbox/pin.env"
  printf 'SKOOTI__KIOSK_PROVE_PUBLIC_KEY_PEM=anything\n' >>"$sandbox/pin.env"
  "$self" --check --repo "$repo" --root "$root" --secrets "$sandbox/pin.env" >"$sandbox/a8b.out" 2>&1; rc=$?
  if [ "$rc" = 2 ] && LC_ALL=C grep -q 'DERIVED value' "$sandbox/a8b.out"; then ok "A8 a vault key for the DERIVED broker pin is refused"
  else bad "A8 exit $rc; the derived pin was settable from the vault"; fi

  # ── A11: the pinned broker key IS the broker's own public half ───────────
  local pinned broker_pub
  pinned=$(awk "$PARSER" "$root/etc/kiosk-demo/skooti.env" | LC_ALL=C grep '^KIOSK_PROVE_PUBLIC_KEY_PEM	' | cut -f2)
  broker_pub=$(awk "$PARSER" "$pf" | LC_ALL=C grep '^PROVE_KEY_PEM	' | cut -f2 | { IFS= read -r e; printf '%b\n' "$e"; } | openssl pkey -pubout 2>/dev/null)
  if [ -n "$broker_pub" ] && [ "$(printf '%b' "$pinned")" = "$broker_pub" ]; then
    ok "A11 each operator pins exactly the public half of the broker's own key"
  else bad "A11 the pinned key is not the broker's public half"; fi

  # ── A12: --apply makes an env file readable by the deploy hook's account ──
  #
  # The hook file is what the account is inferred from when --hook-account is
  # not given, so every arm from here on has one. MODE is tested for real; a
  # chown to a SECOND account is not, because a sandbox with no privileges
  # cannot do one — what is tested there is that the refusal is reported.
  mkdir -p "$root/srv/kiosk.git/hooks"
  printf '#!/bin/sh\n: a stand-in for the box hook\n' >"$root/srv/kiosk.git/hooks/post-receive"
  chmod +x "$root/srv/kiosk.git/hooks/post-receive"
  local me plf=$root/etc/kiosk-demo/philslist.env lines
  me=$(id -u)

  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" --hook-account 65534 >"$sandbox/a12.out" 2>&1; rc=$?
  if [ "$rc" = 1 ]; then ok "A12 --check reddens when the deploy hook cannot read an env file (exit 1)"
  else bad "A12 --check exit $rc, want 1"; fi
  lines=$(LC_ALL=C grep -c '^    ACCESS ' "$sandbox/a12.out")
  if [ "$lines" = 8 ]; then ok "A12 one line per file and nothing more (8)"; else bad "A12 $lines ACCESS lines, want 8"; fi

  "$self" --apply --repo "$repo" --root "$root" --secrets "$vault" --hook-account 65534 >"$sandbox/a12b.out" 2>&1; rc=$?
  if [ "$rc" = 1 ]; then ok "A12 --apply that cannot give a file to the hook account fails the run (exit 1)"
  else bad "A12 --apply exit $rc, want 1"; cat "$sandbox/a12b.out"; fi
  if LC_ALL=C grep -q 'unchanged.*philslist.env' "$sandbox/a12b.out"; then
    ok "A12 the content was already right, so this is the access path and nothing else"
  else bad "A12 the file was rewritten; the access half of this arm proves nothing"; fi
  case "$(file_attrs "$plf")" in *" 0640") ok "A12 and --apply gave it the mode the deploy hook needs (0640)" ;;
    *) bad "A12 philslist.env is $(file_attrs "$plf"), want mode 0640" ;; esac
  if LC_ALL=C grep -q 'chown was refused' "$sandbox/a12b.out"; then ok "A12 a chown it cannot do is said out loud, never swallowed"
  else bad "A12 the refused chown was not reported"; fi

  # A file that is already right is left alone, and a wide one is narrowed —
  # this script never widens a mode to reach its target.
  chmod 0644 "$plf"
  "$self" --apply --repo "$repo" --root "$root" --secrets "$vault" --hook-account "$me" >"$sandbox/a12c.out" 2>&1; rc=$?
  case "$(file_attrs "$plf")" in *" 0640") ok "A12 a world-readable env file is narrowed to 0640" ;;
    *) bad "A12 philslist.env is $(file_attrs "$plf") after --apply, want mode 0640" ;; esac
  local was; was=$(file_attrs "$plf")
  "$self" --apply --repo "$repo" --root "$root" --secrets "$vault" --hook-account "$me" >"$sandbox/a12d.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && [ "$(file_attrs "$plf")" = "$was" ]; then ok "A12 a file that is already right is left exactly as it is"
  else bad "A12 the second --apply moved $was -> $(file_attrs "$plf") (exit $rc)"; fi
  if LC_ALL=C grep -q 'ACCESS' "$sandbox/a12d.out"; then bad "A12 it reported an access change it did not make"
  else ok "A12 and says nothing about access when there is nothing to say"; fi

  # A file this script CREATES gets the same posture as one it corrects.
  local tf=$root/etc/kiosk-demo/tudu.env
  rm -f "$tf"
  "$self" --apply --generate-missing --repo "$repo" --root "$root" --secrets "$vault" --hook-account "$me" >"$sandbox/a12e.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && [ -f "$tf" ]; then ok "A12 --apply re-created a deleted env file"; else bad "A12 exit $rc; $tf was not re-created"; cat "$sandbox/a12e.out"; fi
  case "$(file_attrs "$tf")" in *" 0640") ok "A12 and gave the new file 0640 too" ;;
    *) bad "A12 the new file is $(file_attrs "$tf"), want mode 0640" ;; esac

  # ── A13: which account, and what happens when there is none ─────────────
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a13.out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A13 --check is green on the tree --apply just settled (exit 0)"; else bad "A13 --check exit $rc, want 0"; cat "$sandbox/a13.out"; fi
  if LC_ALL=C grep -q 'INFERRED from who owns' "$sandbox/a13.out"; then ok "A13 with no --hook-account it names the inference it made"
  else bad "A13 it did not say the hook account was inferred"; fi
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" --hook-account nosuchaccount-zz >"$sandbox/a13b.out" 2>&1; rc=$?
  if [ "$rc" = 2 ]; then ok "A13 --hook-account naming no account on this box refuses (exit 2)"
  else bad "A13 --hook-account with an unknown name exited $rc, want 2"; fi

  # No hook file and no --hook-account: the account is undetermined, and a run
  # that cannot say who must read a file does not get to change who does.
  local nohook=$sandbox/nohook nplf
  mkdir -p "$nohook/etc"
  cp -R "$root/etc/kiosk-demo" "$nohook/etc/kiosk-demo"
  nplf=$nohook/etc/kiosk-demo/philslist.env
  LC_ALL=C sed 's/^PORT=3006$/PORT=9998/' "$nplf" >"$nohook/mut.env" && mv "$nohook/mut.env" "$nplf"
  chmod 0644 "$nplf"
  "$self" --apply --repo "$repo" --root "$nohook" --secrets "$vault" >"$sandbox/a13c.out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A13 --apply runs with no hook file at all (exit 0)"; else bad "A13 exit $rc, want 0"; cat "$sandbox/a13c.out"; fi
  if LC_ALL=C grep -q 'UNDETERMINED' "$sandbox/a13c.out"; then ok "A13 and says the account is undetermined rather than reporting agreement"
  else bad "A13 an undetermined hook account was not reported"; fi
  if LC_ALL=C grep -q '^PORT=3006$' "$nplf"; then ok "A13 the file really was rewritten (the drifted PORT is corrected)"
  else bad "A13 the file was NOT rewritten, so the arm below proves nothing"; fi
  case "$(file_attrs "$nplf")" in *" 0644") ok "A13 and it kept the mode it had across the rewrite" ;;
    *) bad "A13 the rewritten file is $(file_attrs "$nplf"), want the 0644 it had" ;; esac

  echo ""
  if [ "$fails" = 0 ]; then echo "rollout.sh --self-test: all arms passed"; return 0; fi
  echo "rollout.sh --self-test: $fails failure(s)"; return 1
}

case "$MODE" in
  check|apply) main_run ;;
  selftest)
    if [ ! -r "$SELF_PATH" ]; then
      echo "rollout.sh: --self-test needs the script as a FILE (it re-runs itself); it cannot run from stdin." >&2
      exit 2
    fi
    selftest; exit $? ;;
  *) usage >&2; exit 2 ;;
esac
