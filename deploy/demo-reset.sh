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
set -uo pipefail
export PATH="/home/ubuntu/.local/bin:/home/ubuntu/.local/share/mise/installs/ruby/4.0.1/bin:$PATH"

WIPE_GG=0; [ "${1:-}" = "--all" ] && WIPE_GG=1

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
  if ! sudo -u postgres psql -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<SQL
DROP DATABASE IF EXISTS "$db" WITH (FORCE);
CREATE DATABASE "$db" OWNER "$role";
REVOKE CONNECT ON DATABASE "$db" FROM PUBLIC;
GRANT CONNECT ON DATABASE "$db" TO "$role";
SQL
  then
    echo "  $a: DB drop/create FAILED (postgres superuser step)"
    sudo systemctl start "kiosk-demo@$a"; return
  fi
  if ( set -a; . "/etc/kiosk-demo/$a.env"; set +a
       bundle exec rails db:schema:load db:seed >/dev/null 2>&1 ); then
    echo "  $a: reset + freshly seeded"
  else
    echo "  $a: schema:load/seed FAILED — run 'bundle exec rails db:schema:load db:seed' in $PWD manually"
  fi
  sudo systemctl start "kiosk-demo@$a"
}

for a in atablefor hoteling skooti stylish philslist tudu; do reset_fresh "$a"; done

if [ "$WIPE_GG" -eq 1 ]; then
  reset_fresh getgrocery
else
  cd /srv/kiosk/kiosk-demo-getgrocery
  if ( set -a; . /etc/kiosk-demo/getgrocery.env; set +a; bundle exec rails db:seed >/dev/null 2>&1 ); then
    echo "  getgrocery: additive re-seed (Hermes order preserved; pass --all to wipe)"
  else
    echo "  getgrocery: SEED FAILED"
  fi
fi

echo "demo-reset done."
