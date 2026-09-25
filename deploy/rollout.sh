#!/usr/bin/env bash
# rollout.sh — the fleet's environment, DECLARED by this repository and written
# onto the box. Run it ON THE BOX.
#
#   ssh <deploy-user>@<box> 'sudo bash -s' -- --check   < deploy/rollout.sh
#   ssh <deploy-user>@<box> 'sudo bash -s' -- --apply   < deploy/rollout.sh
#
# ── WHY IT EXISTS ───────────────────────────────────────────────────────────
#
# Until this script, NO FILE IN ANY REPOSITORY DROVE `/etc/kiosk-demo/*.env`.
# `box-prep-2026-08-11.sh` says so in its own header — it edits «only the
# hand-maintained /etc/kiosk-demo/*.env files, which no repo file drives» — and
# that is exactly how both KYC operators spent thirty-five days answering
# `501 module_not_served` with a correct secret stored under a name the app had
# stopped reading. A one-shot patch written on the day a defect is found repairs
# that day. It cannot say what the configuration SHOULD be, so it cannot answer
# the two questions that matter: is the box right now, and what happens if the
# box is wiped.
#
# This script answers both, because it is DECLARATIVE. It does not patch; it
# states what each unit must carry and makes the file say that. Run it on a
# correct box and nothing changes and it says so. Run it on a drifted box and it
# says exactly what it changed. Run it on a box rebuilt from nothing and it
# builds every env file from the shipped templates — or, for a value it cannot
# honestly obtain, it names that value and STOPS, which is the whole of its
# posture: A BLANK IS WORSE THAN A REFUSAL.
#
# ── WHAT DECLARES THE CONFIGURATION ─────────────────────────────────────────
#
# `deploy/env/<name>.env.example`, in the checkout at $KIOSK_REPO (default
# /srv/kiosk). Those files already carry the variable set, the order, the
# comments and every value this repository gets to decide — port, issuer,
# database name, login role, PoW difficulty, PoW mode, broker URL, callback
# host. This script does not repeat any of that. It renders the template and
# fills the `REPLACE_*` slots, so the file on the box becomes the file in the
# tree with its secrets in place, comments and all.
#
# The consequence worth stating: TO CHANGE THE FLEET'S CONFIGURATION, EDIT THE
# TEMPLATE AND RE-RUN THIS. There is no second place to edit, and no step where
# a human retypes a name.
#
# AND THE DECLARATION IS THE CHECKOUT ON THE BOX, NOT `main`. That is the right
# pairing — an env file belongs to the code that reads it, and /srv/kiosk is the
# code the units are running — but it means a box behind `main` is checked
# against templates that are behind it too. If the answer you want is «does the
# fleet match HEAD», deploy first and run this after.
#
# The unit name is the template's name, with the one documented exception:
# `kyc-demo.env.example` configures the unit `prove`, because the KYC broker's
# gem directory is `kiosk-demo-prove` while it serves kyc.demo.kiosk.tech.
# `kiosk-demo@.service`'s own header carries that exception; this script reads
# the PORT it renders back out, so a mis-mapping shows up as a port mismatch
# rather than as a silent write to the wrong file.
#
# ── WHERE SECRETS COME FROM, AND WHAT HAPPENS ON A WIPED BOX ────────────────
#
# NO SECRET IS IN THIS FILE AND NO SECRET IS EVER PRINTED. A value is resolved
# from, in order:
#
#   1. the VAULT — an operator-supplied file of `<UNIT>__<VARIABLE>=value`
#      lines, default /etc/kiosk-demo/secrets.env, override with --secrets.
#      This is what an operator restores from their own password manager.
#   2. the value already in /etc/kiosk-demo/<unit>.env. A healthy box therefore
#      sources every secret from itself, and a re-run ROTATES NOTHING.
#
# There is no third source, and in particular there is no prompt: this script is
# meant to arrive over `bash -s`, so its stdin is the script and there is nobody
# to ask. That is a constraint, not a preference, and it is why the vault file
# lives on the box rather than being typed.
#
# ON A WIPED BOX both sources are empty for every secret, and what happens then
# is the question this script exists to answer plainly:
#
#   * --apply alone REFUSES. It names every unresolvable variable, per unit,
#     and writes NOTHING — not one file, not one blank. Exit 2.
#   * --apply --generate-missing mints the values NOTHING OUTSIDE
#     /etc/kiosk-demo CAN HOLD THE OTHER HALF OF, and only those:
#       SECRET_KEY_BASE, KIOSK_POW_SECRET, KIOSK_SIGNING_KEY_B64, and the
#       shared KYC intake secret (both sides of which live on this box).
#     It still REFUSES, by name and with the command to produce each, the four
#     whose other half is somewhere else:
#       KIOSK_<APP>_DB_PASSWORD  — Postgres holds it; deploy/postgres-init.sql
#                                  sets it, and a minted one cannot match.
#       STRIPE_SECRET_KEY        — Stripe issues it.
#       KIOSK_UNLOCK_SIGNING_KEY_PEM — its public half is flashed into physical
#                                  scooter locks; a new one bricks every lock.
#       PROVE_KEY_PEM            — the KYC broker's identity; a new one
#                                  invalidates every attestation already issued.
#     Minting a signing key or a session key logs every assistant out. That is
#     free on a wiped box (the accounts went with it) and is NOT free on a box
#     whose database survived, so --generate-missing is opt-in per run and
#     prints the name of everything it minted.
#
# ONE VALUE IS DERIVED RATHER THAN SOURCED. Each KYC operator's
# `KIOSK_PROVE_PUBLIC_KEY_PEM` is computed from the broker's `PROVE_KEY_PEM` on
# this same box, so the pinned key cannot disagree with the key the broker
# signs with. A vault entry for it is REFUSED rather than ignored.
#
# ── THE KYC PAIR: ONE SECRET, TWO FILES, TWO NAMES ──────────────────────────
#
# The operator reads the role-named `KIOSK_PROVE_INTAKE_SECRET`; the broker
# reads a per-operator `KIOSK_PROVE_<OP>_SECRET`. That asymmetry is by design —
# the operator demos' production.rb is byte-identical and so must not name a
# demo, while the broker serves several operators and must tell them apart —
# and it is the exact shape that went wrong for thirty-five days. So this script
# models it as ONE secret with ONE vault name, `KYC_INTAKE_SECRET_<OP>`, and
# writes both sides from it. A vault entry that would set one side alone
# (`<OP>__KIOSK_PROVE_INTAKE_SECRET`, `PROVE__KIOSK_PROVE_<OP>_SECRET`) is
# REFUSED by name. It is not possible to half-relink the pair through this
# script, and --check pairs the two sides BY VALUE on every run.
#
# AND WHEN BOTH SIDES ARE LIVE AND THEY DISAGREE, THE SCRIPT REFUSES rather than
# picking one. Taking the broker's would silently re-key the operator; taking the
# operator's would silently re-key the broker's registry entry. Neither is a
# thing a configuration run gets to decide on its own, so it names the pair and
# stops, and the vault key `KYC_INTAKE_SECRET_<OP>` is how a human says which
# value is the real one.
#
# ── THREE TIERS OF DISAGREEMENT, AND ONLY ONE OF THEM IS RED ────────────────
#
# CONFIG — a declared variable missing or empty, a declared non-secret value
#   that differs from what the tree says, a retired name still assigned, a KYC
#   pair that does not pair, a secret that cannot be resolved. `--check` exits 1.
# FORM — the file is not byte-identical to what `--apply` would write: a
#   different order, drifted comments, a variable nobody declares. Reported,
#   never red, because the first run against a hand-maintained fleet would
#   otherwise arrive red for a cosmetic reason and teach nobody anything —
#   which is how a check gets switched off. `--check --strict` reddens on it
#   too, and one `--apply` drains it for good.
# ACCESS — who can READ each env file: its owner, its group, its mode, and
#   whether the account the push-to-deploy hook runs as is among them. Never
#   red, in any mode, not even under --strict, and for a reason stronger than
#   the FORM tier's: this script does not set those attributes and cannot
#   repair what it reports, so a red exit would be a gate over somebody else's
#   decision. It is an observation whose whole job is to be READ — the class of
#   fact that, unobserved, cost eight units their `db:migrate` under a deploy
#   that still said «deploy complete». `--hook-account` names the reader when
#   you know it; otherwise the report says what it inferred it from.
#
# ── WHAT IT DOES NOT DO ─────────────────────────────────────────────────────
#
# IT DOES NOT TOUCH CADDY. /etc/caddy/Caddyfile is `deploy/deploy-caddy.sh`'s
# alone and is never hand-edited or patched from here.
# IT DOES NOT RESTART ANYTHING. A restart is a visible production event and a
# decision; the script prints the exact `systemctl restart` line for each unit
# whose file it changed, and stops there.
# IT DOES NOT TOUCH POSTGRES, run migrations, or seed. `db:migrate` and
# `db:seed` belong to the push-to-deploy hook (deploy/CHECKLIST.md §7).
# IT DOES NOT READ THE PROVE BROKER OVER THE NETWORK. Everything it needs is in
# /etc/kiosk-demo and the checkout.
# IT DOES NOT CHANGE OWNERSHIP OR MODE ON A FILE THAT ALREADY EXISTS. A
# configuration run edits CONTENT; see the next section for why that is a rule
# and not a preference.
#
# ── OWNERSHIP AND MODE BELONG TO THE BOX, NOT TO THIS SCRIPT ────────────────
#
# AN ENV FILE HAS MORE READERS THAN THE UNIT THAT NAMES IT. `kiosk-demo@.service`
# hands it to Puma through `EnvironmentFile=` as `kiosk`, and
# /srv/kiosk.git/hooks/post-receive ALSO sources every one of them, as whatever
# account a push arrives as. This script cannot enumerate the readers of a file
# it did not create, so it does not get to decide who they are:
#
#   * A FILE THAT ALREADY EXISTS KEEPS ITS OWNER, ITS GROUP AND ITS MODE,
#     exactly. They are read BEFORE the write and re-applied after it, because
#     the rename that installs the new text replaces the inode and would
#     otherwise hand the file whatever the running shell's umask says.
#   * A FILE THIS SCRIPT CREATES has no prior attributes to preserve, and it
#     still does not invent any. It takes them from a sibling `<unit>.env` in
#     the same directory when there is one — the strongest evidence there is of
#     what this box's readers of env files are set up to read — and otherwise
#     from the directory itself: its owner, its group, and its mode with the
#     execute bits cleared, which is the file counterpart of the reach the
#     directory already grants. Both sources are somebody's decision about this
#     box rather than this script's, and neither can be NARROWER than the
#     directory a reader already has to traverse, so neither can shut out a
#     reader this script cannot see. Every create says which of the two it used.
#
# AN INHERITED MODE CAN BE WIDER THAN AN ENV FILE DESERVES — a directory left at
# 0755 yields a 0644 file, and these files carry secrets. The script SAYS SO on
# the create rather than narrowing it, because the one place a box states who may
# reach these files is the directory, and an operator who tightens that gets
# every file with it. Inventing 0600 here is precisely the move that took the
# deploy hook's read away, and it would be the same move whatever number was
# invented.
#
# THE THIRD OPTION — refuse, and make the operator state the triple — is the one
# this script does NOT take, and the reason is its own purpose: a wiped box must
# be rebuildable from the tree, and a create that stops on a question an
# operator has no better answer to than the directory does would end that.
#
# It is written out because the weak version cost a production deploy. A run
# that ended `chmod 0600` and `chown kiosk` took the hook's access away on all
# eight units at once; every `db:migrate` then failed with «Permission denied»
# and the push still printed «deploy complete». The units were unaffected — they
# read the file as `kiosk` — so nothing went down and nothing was lost, and the
# next deploy carrying a migration would have skipped it in silence.
#
# ── WHAT IT LEAVES BEHIND ───────────────────────────────────────────────────
#
# For every file it modifies, a dated sibling `<file>.bak-YYYY-MM-DD`, created
# once per day per file and never overwritten — the same shape
# box-prep-2026-08-11.sh leaves, and made with `cp -p`, so it carries the
# attributes the file had before the write. Nothing else: no state file, no
# lock, no log. A run whose exit code you did not see is not a result, so every
# mode prints a verdict line and exits 0 (in agreement), 1 (CONFIG drift) or 2
# (refused: something could not be resolved, parsed, or is not allowed).
#
# `--self-test` builds its own throwaway tree under `mktemp -d`, proves the
# parser, idempotence, drift correction, the refusal on a missing secret, the
# KYC pairing both ways and that no secret reaches the output, and touches no
# host and no /etc. It runs in CI.

set -uo pipefail

VERSION_LINE="deploy/rollout.sh"
STAMP=$(date -u +%Y-%m-%d)

# ── The template values that are SLOTS, and what each one is ────────────────
#
# Every `REPLACE_*` value in every shipped template must appear here. A new slot
# nobody classified is REFUSED rather than guessed at — see arm A10 of
# --self-test, which is what stops this table from quietly falling behind
# deploy/env/.
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
      # The per-operator spelling belongs to the BROKER. On an operator unit it
      # is the 2026-08-13 rename that cost thirty-five days.
      if [ "${IS_OPERATOR[$unit]:-0}" = 1 ]; then
        echo "the operator side was renamed to KIOSK_PROVE_INTAKE_SECRET on 2026-08-13 and nothing has read this spelling since"
      fi ;;
  esac
}

# ── Parsing an env file without executing it ────────────────────────────────
#
# `kyc-pairing-audit.sh` reads a value by SOURCING the file, which is correct
# for a file written to be sourced and is the convention on this box. This
# script does not, for one reason: it rewrites what it reads, so a file it
# cannot parse must be REFUSED rather than run. The grammar it accepts is the
# grammar the templates are written in — `NAME=value`, an optional `export`,
# single or double quotes, a double-quoted value spanning lines (which is how a
# PEM is carried), `#` comments and blank lines. Anything else fails with its
# line number, and nothing is written.
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
  --hook-account USER    the account the push-to-deploy hook runs as, when you know it;
                         otherwise it is inferred from who owns the hook file
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

# A --hook-account naming nothing is a typo, and it is refused HERE rather than
# where it is used: the flag only steers a report, so a run that is going to
# refuse it must refuse before it writes a file.
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

  [ "$issues" = 1 ] && CONFIG_DRIFT=1

  if ! cmp -s "$rendered" "$f"; then
    [ "$issues" = 0 ] && echo "    FORM    every declared value agrees; the file differs in order or comments"
    FORM_DRIFT=1
    CHANGED_UNITS="$CHANGED_UNITS $unit"
  elif [ "$issues" = 0 ]; then
    echo "    ok      every declared variable is in place"
  fi
}

# ── Owner, group and mode: READ, never decided ──────────────────────────────
#
# See the header section «OWNERSHIP AND MODE BELONG TO THE BOX». Everything
# below only ever observes what is there and puts it back.
#
# stat(1) is two different programs on the two systems this runs on — the box is
# Linux (GNU coreutils) and --self-test also runs on macOS (BSD) — and they share
# no format flag. Ask GNU first, fall back to BSD, print nothing when neither
# answers, and let every caller treat «nothing» as «I do not know» rather than as
# an all-clear.
file_attrs() {   # file_attrs <path> ; "<uid> <gid> <4-digit octal mode>" on stdout
  local raw uid gid mode
  raw=$(stat -c '%u %g %a' "$1" 2>/dev/null) || raw=$(stat -f '%u %g %Lp' "$1" 2>/dev/null) || return 1
  read -r uid gid mode <<<"$raw"
  [ -n "$mode" ] || return 1
  printf '%s %s %04o\n' "$uid" "$gid" "$((8#$mode))"
}

# Where a file this script CREATES takes its attributes from. A sibling env file
# first, the directory second; both are somebody else's decision about this box.
new_file_attrs() {   # new_file_attrs <path-to-be-created> ; "<uid> <gid> <mode> <in words>"
  local f=$1 d s a uid gid mode
  d=${f%/*}
  for s in "$d"/*.env; do
    [ -f "$s" ] || continue
    [ "$s" = "$f" ] && continue
    case "${s##*/}" in secrets.env) continue ;; esac
    a=$(file_attrs "$s") || continue
    printf '%s the sibling %s\n' "$a" "${s##*/}"
    return 0
  done
  a=$(file_attrs "$d") || return 1
  read -r uid gid mode <<<"$a"
  # The file counterpart of a directory's mode: `x` on a directory means «may
  # traverse», and a file has nothing to traverse.
  printf '%s %s %04o the directory %s\n' "$uid" "$gid" "$(( 8#$mode & ~8#111 ))" "$d"
}

# Put back exactly what was read. chmod on a file you own always works; chown
# does not, so it is attempted only when the triple actually differs and its
# refusal is REPORTED rather than swallowed — a silently un-restored owner is
# the whole defect this section exists to end.
apply_attrs() {   # apply_attrs <path> <uid> <gid> <mode>
  local f=$1 uid=$2 gid=$3 mode=$4 now nuid ngid _nmode
  if [ -n "$mode" ] && ! chmod "$mode" "$f"; then
    echo "    WARNING    could not set mode $mode on $f"
  fi
  now=$(file_attrs "$f") || now=""
  read -r nuid ngid _nmode <<<"$now"
  if [ -n "$uid" ] && { [ "$uid" != "${nuid:-}" ] || [ "$gid" != "${ngid:-}" ]; }; then
    if ! chown "$uid:$gid" "$f" 2>/dev/null; then
      echo "    WARNING    $f is owned by ${nuid:-?}:${ngid:-?} and should be $uid:$gid — chown was refused"
      echo "               (re-run as root; a reader of this file may have lost access)"
    fi
  fi
}

# ── Writing ─────────────────────────────────────────────────────────────────
install_unit() {   # install_unit <unit> <rendered-file>
  local unit=$1 rendered=$2
  local f="$ENVDIR/$unit.env" bk="$ENVDIR/$unit.env.bak-$STAMP"
  if [ -f "$f" ] && cmp -s "$rendered" "$f"; then
    echo "    unchanged  $f"
    return
  fi
  if [ -f "$f" ] && [ ! -f "$bk" ]; then
    cp -p "$f" "$bk" || { echo "    FAILED     could not back $f up to $bk — nothing written" >&2; return 1; }
    echo "    backup     $bk"
  fi

  # READ THE ATTRIBUTES BEFORE THE WRITE. The rename below replaces the inode,
  # so what is read here is the only record of what the file was.
  local attrs="" origin="" origin_rest="" auid="" agid="" amode=""
  if [ -f "$f" ]; then
    attrs=$(file_attrs "$f") || attrs=""
    origin="the file as it stood"
  else
    attrs=$(new_file_attrs "$f") || attrs=""
    origin=""
  fi
  if [ -n "$attrs" ]; then
    read -r auid agid amode origin_rest <<<"$attrs"
    [ -n "$origin" ] || origin=$origin_rest
  fi

  ( umask 077; cat "$rendered" >"$f.rollout-new" ) || return 1
  mv "$f.rollout-new" "$f" || return 1
  if [ -n "$attrs" ]; then
    apply_attrs "$f" "$auid" "$agid" "$amode"
    echo "    WROTE      $f  ($auid:$agid $amode, from $origin)"
    # A created file inherits, and an inherited mode can be wider than an env
    # file's contents deserve. Saying so is this script's whole part in it: the
    # remedy is to tighten the DIRECTORY, which is the one place a box states
    # who reaches these files, and NOT for this script to invent 0600 — that
    # invention is what took the deploy hook's read away on 2026-09-25.
    if [ "$origin" != "the file as it stood" ] && [ $(( 8#$amode & 8#004 )) -ne 0 ]; then
      echo "    NOTE       $amode leaves this file readable by every account on the box, and it"
      echo "               carries secrets. It was inherited from $origin. If that is not what"
      echo "               you meant, tighten $ENVDIR and re-run — do not hand-edit the file."
    fi
  else
    echo "    WROTE      $f"
    echo "    WARNING    could not read an owner, group or mode to give this file — it carries"
    echo "               whatever this shell's umask left. Set it by hand and re-run --check."
  fi
  CHANGED_UNITS="$CHANGED_UNITS $unit"
}

# ── The deploy hook, OBSERVED and never written ─────────────────────────────
#
# /srv/kiosk.git/hooks/post-receive is the only thing that turns a push into a
# deploy and it exists in no repository (deploy/CHECKLIST.md §7).
# This script will not write it and does not pretend to know it. What it can
# honestly do is say whether it is still there and what its fingerprint is, so
# that a wipe is something the fleet's own configuration run REPORTS rather than
# something discovered on the next push.
HOOK_FILE=""
observe_hook() {
  HOOK_FILE=${ROOT}/srv/kiosk.git/hooks/post-receive
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

# ── Who ELSE reads these files — the ACCESS tier ────────────────────────────
#
# The hook above sources every /etc/kiosk-demo/*.env, as whatever account the
# push authenticated as. That account is NOT on disk anywhere: git runs the hook
# as the ssh user, and no file records who that is. So this section reports what
# it can actually measure and names the evidence it measured it from, and when
# it has none it SAYS SO rather than reporting agreement.
#
#   --hook-account <user>  you know the account; the report uses it and says so.
#   otherwise              the owner of the hook file, which is an INFERENCE:
#                          a push-to-deploy repository is normally owned by the
#                          account that receives the push — and «normally» is
#                          not «always».
resolve_hook_account() {   # sets HOOK_UID and HOOK_UID_FROM; HOOK_UID empty = undetermined
  HOOK_UID=""
  HOOK_UID_FROM=""
  if [ -n "$HOOK_ACCOUNT_UID" ]; then
    HOOK_UID=$HOOK_ACCOUNT_UID
    HOOK_UID_FROM="--hook-account $HOOK_ACCOUNT_ARG, stated on the command line"
    return
  fi
  local a uid gid mode
  if [ -f "$HOOK_FILE" ] && a=$(file_attrs "$HOOK_FILE"); then
    read -r uid gid mode <<<"$a"
    HOOK_UID=$uid
    HOOK_UID_FROM="INFERRED from who owns $HOOK_FILE — git runs the hook as the account the push arrives as, which is not recorded anywhere"
  fi
}

uid_label() {   # uid_label <uid> ; "name (uid N)" or "uid N"
  local n
  n=$(id -un "$1" 2>/dev/null)
  if [ -n "$n" ]; then printf '%s (uid %s)' "$n" "$1"; else printf 'uid %s' "$1"; fi
}

uid_in_group() {   # uid_in_group <uid> <gid> ; 0 yes · 1 no · 2 cannot tell
  local n g
  n=$(id -un "$1" 2>/dev/null) || return 2
  [ -n "$n" ] || return 2
  g=$(id -G "$n" 2>/dev/null) || return 2
  [ -n "$g" ] || return 2
  case " $g " in *" $2 "*) return 0 ;; esac
  return 1
}

has_perm() {   # has_perm <uid> <f-uid> <f-gid> <octal-mode> <4=read|1=execute> ; yes|no|unknown
  local u=$1 fu=$2 fg=$3 m=$4 b=$5 bits g
  if [ "$u" = 0 ]; then echo yes; return; fi
  bits=$((8#$m))
  if [ "$u" = "$fu" ]; then
    if [ $(( bits & (b * 64) )) -ne 0 ]; then echo yes; else echo no; fi
    return
  fi
  if [ $(( bits & b )) -ne 0 ]; then echo yes; return; fi
  uid_in_group "$u" "$fg"; g=$?
  if [ $(( bits & (b * 8) )) -eq 0 ]; then echo no; return; fi
  case $g in
    0) echo yes ;;
    1) echo no ;;
    *) echo unknown ;;
  esac
}

observe_readers() {
  echo "== who can READ the env files (observed; never red, in any mode) =="
  resolve_hook_account
  if [ -n "$HOOK_UID" ]; then
    echo "    the deploy hook runs as: $(uid_label "$HOOK_UID")"
    echo "        $HOOK_UID_FROM"
  else
    echo "    the deploy hook runs as: UNDETERMINED — $HOOK_FILE is not here and no"
    echo "        --hook-account was given, so this run cannot say who reads these files."
    echo "        THAT IS NOT AGREEMENT. Pass --hook-account <user> to have it checked."
  fi

  local a duid dgid dmode dx
  if a=$(file_attrs "$ENVDIR"); then
    read -r duid dgid dmode <<<"$a"
    echo "    directory  $ENVDIR  $(uid_label "$duid"):$dgid  $dmode"
    if [ -n "$HOOK_UID" ]; then
      dx=$(has_perm "$HOOK_UID" "$duid" "$dgid" "$dmode" 1)
      if [ "$dx" = no ]; then
        echo "    WARNING    that account cannot TRAVERSE this directory, so it reaches none of"
        echo "               the files below whatever their own modes say."
      fi
    fi
  else
    echo "    directory  $ENVDIR — attributes unreadable"
  fi

  local unit f r
  for unit in $(printf '%s\n' "${!TPL_FOR_UNIT[@]}" | sort); do
    f="$ENVDIR/$unit.env"
    if [ ! -f "$f" ]; then continue; fi
    if ! a=$(file_attrs "$f"); then echo "    $unit.env — attributes unreadable"; continue; fi
    local fuid fgid fmode
    read -r fuid fgid fmode <<<"$a"
    if [ -z "$HOOK_UID" ]; then
      echo "    $unit.env  $(uid_label "$fuid"):$fgid  $fmode"
      continue
    fi
    r=$(has_perm "$HOOK_UID" "$fuid" "$fgid" "$fmode" 4)
    case "$r" in
      yes) echo "    $unit.env  $(uid_label "$fuid"):$fgid  $fmode   readable by the deploy hook's account" ;;
      unknown)
        echo "    $unit.env  $(uid_label "$fuid"):$fgid  $fmode   readable ONLY through group $fgid, and this"
        echo "               run could not resolve that account's groups — unverified, not agreement" ;;
      *)
        echo "    WARNING    $unit.env  $(uid_label "$fuid"):$fgid  $fmode — NOT readable by $(uid_label "$HOOK_UID")."
        echo "               The push-to-deploy hook sources this file. If that is the account it runs"
        echo "               as, its db:migrate for $unit fails with «Permission denied» and the push"
        echo "               still reports a completed deploy. See deploy/README.md, «Give the env"
        echo "               files their permissions back»." ;;
    esac
  done
  echo ""
}

main_run() {
  load_declaration
  load_vault
  check_vault_forbidden
  load_box
  resolve_all

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
  observe_readers

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

  # ── A12: an EXISTING file keeps its owner, group and mode across --apply ──
  #
  # This is the 2026-09-25 regression, in a tree we own. The old code ended
  # every write with `chmod 0600` and `chown kiosk`, which is how the deploy
  # hook lost its read on all eight units at once. MODE is tested for real —
  # 0640 survives, and the old line would have made it 0600. GROUP is tested
  # for real too, and it is the arm that proves the attributes are re-applied
  # AFTER the rename rather than merely left alone: the temp file this script
  # writes takes the DIRECTORY's group, so a rename with no re-apply loses it.
  # UID is NOT tested, because a sandbox with no privileges cannot chown to a
  # second account; the uid half of install_unit is covered by reading it.
  local plf=$root/etc/kiosk-demo/philslist.env before_attrs after_attrs
  local want_gid="" g
  chmod 0640 "$plf"
  for g in $(id -G); do
    if [ "$g" != "$(file_attrs "$plf" | cut -d' ' -f2)" ]; then want_gid=$g; break; fi
  done
  if [ -n "$want_gid" ] && chgrp "$want_gid" "$plf" 2>/dev/null; then
    ok "A12 the fixture carries a distinctive group ($want_gid) — the arm is not vacuous"
  else
    want_gid=""
    bad "A12 could not give the fixture a second group; the group half of this arm did not run"
  fi
  before_attrs=$(file_attrs "$plf")
  LC_ALL=C sed 's/^PORT=3006$/PORT=9998/' "$plf" >"$plf.mut" && mv "$plf.mut" "$plf"
  chmod 0640 "$plf"; [ -n "$want_gid" ] && chgrp "$want_gid" "$plf"
  "$self" --apply --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a12.out" 2>&1; rc=$?
  after_attrs=$(file_attrs "$plf")
  if [ "$rc" = 0 ]; then ok "A12 --apply ran (exit 0)"; else bad "A12 --apply exit $rc, want 0"; cat "$sandbox/a12.out"; fi
  if LC_ALL=C grep -q '^PORT=3006$' "$plf"; then ok "A12 the file really was rewritten (the drifted PORT is corrected)"
  else bad "A12 the file was NOT rewritten, so this arm proves nothing"; fi
  if [ "$before_attrs" = "$after_attrs" ]; then ok "A12 owner, group and mode are unchanged across the write ($after_attrs)"
  else bad "A12 attributes moved: $before_attrs -> $after_attrs"; fi
  case "$after_attrs" in *" 0640") ok "A12 the distinctive mode 0640 survived (the old chmod 0600 would not have)" ;;
    *) bad "A12 mode is not 0640: $after_attrs" ;; esac

  # ── A12b: a file this script CREATES inherits from a sibling ─────────────
  local af=$root/etc/kiosk-demo/atablefor.env tf=$root/etc/kiosk-demo/tudu.env
  chmod 0640 "$af"
  rm -f "$tf"
  "$self" --apply --generate-missing --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a12b.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && [ -f "$tf" ]; then ok "A12b --apply re-created the deleted env file"; else bad "A12b exit $rc; $tf was not re-created"; cat "$sandbox/a12b.out"; fi
  case "$(file_attrs "$tf")" in *" 0640") ok "A12b the new file took 0640 from a sibling, not a mode this script chose" ;;
    *) bad "A12b the new file is $(file_attrs "$tf"), not the sibling's 0640" ;; esac
  if LC_ALL=C grep -q 'from the sibling atablefor.env' "$sandbox/a12b.out"; then ok "A12b and it says where it took them from"
  else bad "A12b the run does not name the file it inherited from"; fi

  # ── A13: --check REPORTS an env file the hook's account cannot read, and
  #         does not redden on it ────────────────────────────────────────────
  mkdir -p "$root/srv/kiosk.git/hooks"
  printf '#!/bin/sh\n: a stand-in for the box hook\n' >"$root/srv/kiosk.git/hooks/post-receive"
  chmod +x "$root/srv/kiosk.git/hooks/post-receive"
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" >"$sandbox/a13.out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A13 --check is green on the tree (exit 0)"; else bad "A13 --check exit $rc, want 0"; cat "$sandbox/a13.out"; fi
  if LC_ALL=C grep -q 'INFERRED from who owns' "$sandbox/a13.out"; then ok "A13 with no --hook-account it names the inference it made"
  else bad "A13 it did not say the hook account was inferred"; fi
  # The fixture is the old code's own output: `chmod 0600`, which is what took
  # the hook's read away on the live fleet. 65534 is neither the owner of it
  # nor in any group of it, so the answer cannot be anything but «cannot read».
  chmod 0600 "$root/etc/kiosk-demo/skooti.env"
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" --hook-account 65534 >"$sandbox/a13b.out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A13 an unreadable-to-the-hook fleet does NOT redden --check (exit 0)"
  else bad "A13 --check went red at $rc on an ACCESS-tier finding; the tier must never be red"; fi
  "$self" --check --strict --repo "$repo" --root "$root" --secrets "$vault" --hook-account 65534 >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then ok "A13 nor under --strict (exit 0)"; else bad "A13 --check --strict exit $rc; the ACCESS tier must not redden even there"; fi
  if LC_ALL=C grep -q 'NOT readable by' "$sandbox/a13b.out"; then ok "A13 and it reports the files that account cannot read"
  else bad "A13 it reported no unreadable file — the arm proves nothing"; fi
  if LC_ALL=C grep -q 'db:migrate' "$sandbox/a13b.out"; then ok "A13 and says what that costs on a push"
  else bad "A13 the warning does not say what the consequence is"; fi
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" --hook-account "$(id -u)" >"$sandbox/a13c.out" 2>&1; rc=$?
  if LC_ALL=C grep -q 'readable by the deploy hook' "$sandbox/a13c.out" && ! LC_ALL=C grep -q 'NOT readable by' "$sandbox/a13c.out"; then
    ok "A13 an account that CAN read them is reported as reading them (both directions covered)"
  else bad "A13 exit $rc; an account that can read every file was not reported as such"; fi
  "$self" --check --repo "$repo" --root "$root" --secrets "$vault" --hook-account nosuchaccount-zz >"$sandbox/a13d.out" 2>&1; rc=$?
  if [ "$rc" = 2 ]; then ok "A13 --hook-account naming no account on this box refuses (exit 2)"
  else bad "A13 --hook-account with an unknown name exited $rc, want 2"; fi

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
