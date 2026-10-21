#!/usr/bin/env bash
# Deploy this checkout's HEAD to the demo box. The push to the box's repository
# runs its post-receive hook (migrate, seed, restart); then rollout.sh writes
# the env files and names each unit that needs a restart.
#
#   deploy/deploy.sh [user@host]     # host defaults to $KIOSK_DEPLOY_HOST
#
# The git remote `prod-demo` names the box's repository.
set -euo pipefail

host=${1:-${KIOSK_DEPLOY_HOST:-}}
[ -n "$host" ] || { echo "deploy.sh: no host. Pass user@host, or set KIOSK_DEPLOY_HOST." >&2; exit 2; }
cd "$(dirname "$0")/.."
git push prod-demo HEAD:main
deploy/rollout.sh "$host"
