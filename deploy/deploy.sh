#!/usr/bin/env bash
# Deploy this checkout's HEAD to the demo box. rollout.sh first writes the env
# files the new code boots with, and stops the deploy when one is incomplete.
# Then the push to the box's repository runs its post-receive hook (migrate,
# seed, restart).
#
#   deploy/deploy.sh [user@host]     # host defaults to $KIOSK_DEPLOY_HOST
#
# The git remote `prod-demo` names the box's repository.
set -euo pipefail

host=${1:-${KIOSK_DEPLOY_HOST:-}}
[ -n "$host" ] || { echo "deploy.sh: no host. Pass user@host, or set KIOSK_DEPLOY_HOST." >&2; exit 2; }
cd "$(dirname "$0")/.."
deploy/rollout.sh "$host"
git push prod-demo HEAD:main
