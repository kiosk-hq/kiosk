#!/usr/bin/env bash
# Kiosk hosted live demos — optional catalog re-seed cron
#
# ─────────────────────────────────────────────────────────────────────────────
# THIS SCRIPT DOES NOT PRUNE ANYTHING (K-615)
# ─────────────────────────────────────────────────────────────────────────────
# It kept the name it was born with, so read this before you trust it: NOTHING
# in this repo reclaims demo accounts on a schedule. No demo ships a retention
# task, and the earlier version of this script only *logged* that fact once per
# app per night. It now does the one thing it can do truthfully:
#
#   RE-SEEDS each app's shared catalog — `db:seed`, which every demo's seeds
#   make idempotent-additive (0 delete_all; verified live on all seven, K-464).
#   It repairs/tops up catalog content; it creates and deletes no accounts.
#
# WHY NO PRUNE: per-agent app-layer isolation makes each demo naturally
# multi-tenant — an assistant sees only its own rows (owner-scoped queries + GUC
# binding); the catalog/seed is shared read-only. One poker's junk is invisible
# to the next poker, so a stampede's throwaway registrations cost DISK and
# nothing else. When that disk matters, reclaim it in one shot with
# `deploy/demo-reset.sh` (drops + freshly seeds the six non-getgrocery demos,
# additively re-seeds getgrocery). A per-account retention job would be new
# destructive production code in seven apps for a job that tool already does.
#
# WORTH KNOWING: the push-to-deploy hook already runs `db:seed` on every push
# (K-464), so this script only adds anything if you want a top-up BETWEEN
# deploys.
#
# NOT INSTALLED ON THE HOSTED BOX. The cron is a deliberate skip
# (deploy/CHECKLIST.md §7, deploy/README.md step 5). This script is kept ready
# for anyone who does want it:
#   0 4 * * *  /srv/kiosk/deploy/prune.sh >> /var/log/kiosk-prune.log 2>&1
#
# Idempotent and safe to re-run. Seeds each app's DB independently.

set -euo pipefail

# Where the demo gem checkouts live (WorkingDirectory root in the systemd unit).
APPS_ROOT="${KIOSK_APPS_ROOT:-/srv/kiosk}"

# The seven Kiosk demos. The prove.my broker (kiosk-demo-prove) is deliberately
# absent: it is an issuer, not a Kiosk operator, and has no demo content to seed
# (deploy/demo-reset.sh leaves it alone for the same reason).
APPS=(getgrocery atablefor hoteling skooti stylish philslist tudu)

log() { printf '[kiosk-reseed %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

reseed_one() {
	local app="$1"
	local dir="${APPS_ROOT}/kiosk-demo-${app}"

	if [[ ! -d "$dir" ]]; then
		log "SKIP ${app}: no checkout at ${dir}"
		return 0
	fi

	log "reseed ${app}: refreshing the shared catalog (additive)"

	# Load the app's env exactly as the systemd unit does (same pattern as
	# demo-reset.sh). `db:seed` depends on `:environment` and so boots the app,
	# and in production the initializers REFUSE to boot without KIOSK_POW_SECRET
	# (K-541) / KIOSK_ISSUER (K-510) / SECRET_KEY_BASE — verified: a bare
	# `RAILS_ENV=production bin/rails demo:reconcile` exits 1 with
	# "KIOSK_POW_SECRET is required outside development/test". Without this
	# sourcing, every app would abort at boot and the loop would log seven WARNs.
	(
		cd "$dir"
		if [ -f "/etc/kiosk-demo/${app}.env" ]; then
			set -a; . "/etc/kiosk-demo/${app}.env"; set +a
		fi
		RAILS_ENV=production bundle exec bin/rails db:seed
	)
}

log "start (apps_root=${APPS_ROOT}; re-seed only — no account prune, see header)"
for app in "${APPS[@]}"; do
	reseed_one "$app" || log "WARN ${app}: re-seed returned non-zero (continuing)"
done
log "done"
