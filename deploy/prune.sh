#!/usr/bin/env bash
# Kiosk hosted live demos — daily housekeeping cron
#
# WHY LIGHT: per-agent app-layer isolation makes each demo naturally
# multi-tenant — an assistant sees only its own rows (owner-scoped queries +
# GUC binding); the catalog/seed is shared read-only. So one poker's junk is
# invisible to the next poker: pollution is self-contained per tenant. No heavy
# mid-flow reset / truncation is needed. This script only:
#   1. PRUNES anonymous demo accounts + their owned rows older than N hours
#      (reclaim disk from a stampede's worth of throwaway registrations).
#   2. RE-SEEDS the shared catalog if a prune (or anything) touched it.
#
# NOT INSTALLED ON THE HOSTED BOX. The daily cron is a deliberate skip
# (deploy/CHECKLIST.md §7, deploy/README.md step 5): with per-agent isolation a
# poker's junk is invisible to the next poker, so disk growth is the only cost
# and a bloated demo DB can be reseeded by hand (deploy/demo-reset.sh). This
# script is kept ready for anyone who does want the cron:
#   0 4 * * *  /srv/kiosk/deploy/prune.sh >> /var/log/kiosk-prune.log 2>&1
#
# Idempotent and safe to re-run. Prunes each app's DB independently.

set -euo pipefail

# Hours of retention for anonymous/unclaimed demo accounts. Override via env.
PRUNE_AGE_HOURS="${KIOSK_PRUNE_AGE_HOURS:-24}"

# Where the demo gem checkouts live (WorkingDirectory root in the systemd unit).
APPS_ROOT="${KIOSK_APPS_ROOT:-/srv/kiosk}"

# app <-> gem-dir map. atablefor's dir is kiosk-demo-atablefor.
APPS=(getgrocery atablefor hoteling skooti stylish philslist tudu)

log() { printf '[kiosk-prune %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

prune_one() {
	local app="$1"
	local dir="${APPS_ROOT}/kiosk-demo-${app}"

	if [[ ! -d "$dir" ]]; then
		log "SKIP ${app}: no checkout at ${dir}"
		return 0
	fi

	log "prune ${app}: accounts + owned rows older than ${PRUNE_AGE_HOURS}h"

	# Prefer an app-provided rake task if the demo ships one (keeps prune logic
	# in-app, where the ownership/GUC rules live). Falls back to a generic
	# owner-scoped delete via runner. Neither task is created by this runbook —
	# wiring `demo:prune` into each app is the telemetry/rename follow-up (below).
	(
		cd "$dir"
		if RAILS_ENV=production bundle exec bin/rails -T 2>/dev/null | grep -q 'demo:prune'; then
			RAILS_ENV=production KIOSK_PRUNE_AGE_HOURS="$PRUNE_AGE_HOURS" \
				bundle exec bin/rails demo:prune
		else
			log "NOTE ${app}: no demo:prune task yet — skipping account prune."
			log "     (add a demo:prune rake task per app in the follow-up; see README.)"
		fi

		# Re-seed the shared read-only catalog if the app ships an idempotent
		# seed task. Safe because the catalog is shared/read-only.
		if RAILS_ENV=production bundle exec bin/rails -T 2>/dev/null | grep -q 'demo:seed'; then
			log "reseed ${app}: refreshing shared catalog"
			RAILS_ENV=production bundle exec bin/rails demo:seed
		fi
	)
}

log "start (retention=${PRUNE_AGE_HOURS}h, apps_root=${APPS_ROOT})"
for app in "${APPS[@]}"; do
	prune_one "$app" || log "WARN ${app}: prune returned non-zero (continuing)"
done
log "done"
