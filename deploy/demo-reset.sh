#!/usr/bin/env bash
# Reset the hosted demo data to a clean, freshly-seeded state.
#
# Run it on the VPS (after a deploy so /srv/kiosk is current):
#   ssh ubuntu@kyc.demo.kiosk.tech 'bash /srv/kiosk/deploy/demo-reset.sh'
#
# By default the six NON-getgrocery demos are DROPPED and freshly seeded (they
# hold only ephemeral "poker" data, so a clean reset is safe and gives the
# current realistic content with no stale rows — K-464). getgrocery is instead
# ADDITIVELY re-seeded so its Hermes-verified order f8bc3efb (cited on the
# landing) survives.
#
#   bash demo-reset.sh          # reset the 6; getgrocery additive (keeps the order)
#   bash demo-reset.sh --all    # ALSO wipe+reseed getgrocery (loses the cited order)
#
# The prove.my broker (kyc.demo) has no demo content and is left untouched.
set -uo pipefail
export PATH="/home/ubuntu/.local/bin:/home/ubuntu/.local/share/mise/installs/ruby/4.0.1/bin:$PATH"

WIPE_GG=0; [ "${1:-}" = "--all" ] && WIPE_GG=1

reset_fresh() {  # db:drop + fresh schema + seed, with the service stopped so the
  local a="$1"   # drop has no open connections; restart after.
  cd "/srv/kiosk/kiosk-demo-$a" || { echo "  $a: no dir"; return; }
  sudo systemctl stop "kiosk-demo@$a"
  if ( set -a; . "/etc/kiosk-demo/$a.env"; set +a
       DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rails db:drop db:create db:schema:load db:seed >/dev/null 2>&1 ); then
    echo "  $a: reset + freshly seeded"
  else
    echo "  $a: RESET FAILED — check bundle exec rails db:setup manually"
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
