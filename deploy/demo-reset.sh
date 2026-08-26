#!/usr/bin/env bash
# Reset the hosted demo data to a clean, freshly-seeded state.
#
# Run it on the VPS (after a deploy so /srv/kiosk is current):
#   ssh ubuntu@kyc.demo.kiosk.tech 'bash /srv/kiosk/deploy/demo-reset.sh'
#
# By default the six NON-getgrocery demos are DROPPED and freshly seeded (they
# hold only ephemeral "poker" data, so a clean reset is safe and gives the
# current realistic content with no stale rows — K-464). getgrocery is instead
# ADDITIVELY re-seeded, because it holds the orders REAL third-party assistants
# placed against this origin — the Hermes-verified order f8bc3efb among them.
# Those rows are evidence of a run that happened, and seeding cannot reproduce
# one: a wipe destroys the record permanently rather than refreshing it. No page
# kiosk.tech serves cites any of these order ids, and this note used to say one
# did (K-986) -- the reason is the evidence, not a link.
#
#   bash demo-reset.sh          # reset the 6; getgrocery additive (keeps the real runs)
#   bash demo-reset.sh --all    # ALSO wipe+reseed getgrocery (destroys them)
#
# The KYC broker (kyc.demo) has no demo content and is left untouched.
#
# IT IS ALSO THE SCHEMA REPAIR, NOT ONLY A DATA ONE (K-1074, K-1083), AND THAT
# IS WHY `db:schema:load` BELOW MATTERS MORE THAN IT LOOKS. A box's database is
# built once and migrated forward forever, so anything the migrate path cannot
# deliver is stuck there permanently: a column APPENDED to a migration already
# recorded in `schema_migrations` never arrives (that is K-1074 — the live tudu
# 500s), and a renumbered migration set aborts `db:migrate` outright on a
# database that already holds those tables (K-1083 — measured, PG::DuplicateTable
# at 20260820130113, one step in, since 2026-08-20). Loading `db/structure.sql`
# sidesteps both by construction: it rebuilds the schema the tree states rather
# than replaying the path that cannot reach it. So when `bin/check-migration-
# replay` names an object the deploy cannot deliver, THIS is the tool — run it
# after deploying head, and then move that gate's FLEET_SCHEMA_BASELINE forward
# to the day you ran it.
#
# IT PRINTS WHAT WENT WRONG, AND THAT IS NOT TIDINESS (K-1084). Every command
# below used to run `>/dev/null 2>&1` with only its exit code read, so the four
# failure branches said WHICH step failed and never WHAT the box said. The
# failures this script can actually meet are the ones no local run reproduces —
# a role without CREATE, a `structure.sql` that will not load into the box's
# Postgres, a seed tripping a constraint only the live data has — and it runs
# over `ssh`, so "run it manually" costs a box round-trip a session may not get
# (a verifier has twice been DENIED even a read-only box probe, K-509). Both
# streams therefore go to ONE per-invocation log; stdout stays quiet so the
# per-app summary lines remain the output, and a failing branch prints the tail
# of that log plus the exact command to re-run. Same shape production-smoke.sh
# already uses for its server log, so this is the in-repo pattern rather than a
# new one.
set -uo pipefail
export PATH="/home/ubuntu/.local/bin:/home/ubuntu/.local/share/mise/installs/ruby/4.0.1/bin:$PATH"

WIPE_GG=0; [ "${1:-}" = "--all" ] && WIPE_GG=1

# One log for the whole run. Kept (and its path printed) when anything failed,
# removed when nothing did — a leftover file on the box is worth far less than
# the diagnosis, and worth nothing at all when there is none.
LOG="$(mktemp -t kiosk-demo-reset.XXXXXX)"
FAILED=0

step() {  # step <app> <label> — announce the step IN THE LOG so the tail below
  printf '\n===== %s: %s =====\n' "$1" "$2" >>"$LOG"   # is attributable
}

diagnose() {  # print what the box actually said, right under the failure line
  FAILED=1
  echo "     ---- last 25 lines of $LOG ----"
  tail -n 25 "$LOG" | sed 's/^/     | /'
  echo "     ---- (full output stays at $LOG) ----"
}

reset_fresh() {  # drop+recreate the DB as the postgres SUPERUSER (the per-app login
  local a="$1"   # role is DB-owner but not superuser/createdb, so `rails db:drop`
  local A; A="$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')"  # can't do it),
  local envf="/etc/kiosk-demo/$a.env"       # then load schema + seed as the app role.
  # The DB/role names come from the app's OWN env file — the same
  # KIOSK_<APP>_DB / KIOSK_<APP>_DB_USER that config/database.yml reads, with the
  # same shipped defaults. Hardcoding them here would drop and recreate a
  # database the app is not connected to whenever an operator overrides a name.
  local names db role
  names="$(
    set -a; [ -f "$envf" ] && . "$envf"; set +a
    dv="KIOSK_${A}_DB"; uv="KIOSK_${A}_DB_USER"
    printf '%s\n%s\n' "${!dv:-kiosk_${a}_production}" "${!uv:-kiosk_${a}}"
  )"
  db="${names%%$'\n'*}"; role="${names##*$'\n'}"
  cd "/srv/kiosk/kiosk-demo-$a" || { echo "  $a: no dir"; return; }
  sudo systemctl stop "kiosk-demo@$a"
  step "$a" "drop/create database as the postgres superuser"
  if ! sudo -u postgres psql -v ON_ERROR_STOP=1 -q >>"$LOG" 2>&1 <<SQL
DROP DATABASE IF EXISTS "$db" WITH (FORCE);
CREATE DATABASE "$db" OWNER "$role";
REVOKE CONNECT ON DATABASE "$db" FROM PUBLIC;
GRANT CONNECT ON DATABASE "$db" TO "$role";
SQL
  then
    echo "  $a: DB drop/create FAILED (postgres superuser step) — re-run by hand with:"
    echo "       sudo -u postgres psql -v ON_ERROR_STOP=1   # DB $db, owner role $role"
    diagnose
    sudo systemctl start "kiosk-demo@$a"; return
  fi
  step "$a" "db:schema:load db:seed as the app role"
  if ( set -a; . "/etc/kiosk-demo/$a.env"; set +a
       bundle exec rails db:schema:load db:seed >>"$LOG" 2>&1 ); then
    echo "  $a: reset + freshly seeded"
  else
    echo "  $a: schema:load/seed FAILED — re-run by hand with:"
    echo "       cd $PWD && set -a && . /etc/kiosk-demo/$a.env && set +a && bundle exec rails db:schema:load db:seed"
    diagnose
  fi
  sudo systemctl start "kiosk-demo@$a"
}

for a in atablefor hoteling skooti stylish philslist tudu; do reset_fresh "$a"; done

if [ "$WIPE_GG" -eq 1 ]; then
  reset_fresh getgrocery
else
  cd /srv/kiosk/kiosk-demo-getgrocery
  step getgrocery "additive db:seed (no drop — the Hermes rows are evidence)"
  if ( set -a; . /etc/kiosk-demo/getgrocery.env; set +a; bundle exec rails db:seed >>"$LOG" 2>&1 ); then
    echo "  getgrocery: additive re-seed (Hermes order preserved; pass --all to wipe)"
  else
    # This is the branch guarding the irreplaceable rows, so it gets the SAME
    # re-run command and the same diagnosis as the other two (K-1084 — it used
    # to be the least informative of the three, naming no command at all).
    echo "  getgrocery: SEED FAILED — re-run by hand with:"
    echo "       cd $PWD && set -a && . /etc/kiosk-demo/getgrocery.env && set +a && bundle exec rails db:seed"
    diagnose
  fi
fi

if [ "$FAILED" -eq 0 ]; then
  rm -f "$LOG"
  echo "demo-reset done."
else
  echo "demo-reset finished WITH FAILURES — full output of every step: $LOG"
  exit 1
fi
