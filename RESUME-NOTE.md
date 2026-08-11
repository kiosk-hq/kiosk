# RESUME-NOTE (T-060) — K-630 delete deploy/prune.sh

Decision (Phil, DECISIONS-LOG K-630-PRUNE-SH-FATE): option (a) DELETE
`deploy/prune.sh` + every reference. Supersedes K-593.

## Sweep result (grep 'prune' whole repo, excl .git)
Reference sites to fix (only these 4 files, plus historical CHANGELOG prose
which STAYS):
- [ ] deploy/prune.sh              — git rm
- [ ] deploy/README.md:20          — "Files in this directory" table row
- [ ] deploy/README.md:92-95       — "Automated (this runbook provides)" para
- [ ] deploy/README.md:131         — step 0 layout list ("prune.sh's APPS_ROOT")
- [ ] deploy/README.md:189-200     — step 5 (cron)
- [ ] deploy/CHECKLIST.md:106-111  — §7 prune-cron bullet
- [ ] deploy/telemetry-init.sql:58 — pointer in the housekeeping comment
- [ ] CHANGELOG.md                 — one new line (rule 5)

All other `prune` hits in the repo are unrelated: jti_store pruning (skooti
firmware), PowSpentStore/AuthChallengeStore/RevocationStore `prune!`, "pruned
canonical migrations" in demo READMEs.

## Executes it? NOTHING.
- .github/workflows/ci.yml: no prune.sh ref (its `cron: "23 5 * * *"` is the
  nightly CI schedule). Do NOT edit ci.yml — another agent owns it.
- deploy/kiosk-demo@.service: no ref.
- No systemd timer, no rake task, no other script, no hook in the repo.
- The push-to-deploy hook (deploy/CHECKLIST.md §7) lives on the box and runs
  checkout/bundle/db:prepare(+db:seed per K-464) — it never called prune.sh.

## No count claim to repair
Only CHANGELOG.md:9 says "all ten files" (historical prose, stays). The table
itself carries no number. No script/spec asserts the deploy/ file list.

## Line to state instead (per the decision)
reclaiming disk = `deploy/demo-reset.sh` by hand; re-seeding = the
push-to-deploy hook's `db:seed` (K-464).

## Do NOT fix (scope rule)
K-626 (open): CHECKLIST §7's hook description lists only `db:prepare`, missing
`db:seed`. Its evidence cites deploy/prune.sh:25-28, which this commit deletes
— report to the orchestrator that the pointer moves to deploy/README.md step 5.
