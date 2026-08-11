# RESUME NOTE — deploy-tail-0811 (K-609 / K-610 / K-615)

Scope: `deploy/**` ONLY. Never touch kiosk-server/**, demos' lib|bin|spec,
.github/workflows/ci.yml (parallel agents own those).

## K-609 — kiosk-demo@.service:14 truncated comment
FACT (git): cf21d1a shipped `NOTE: atablefor's gem dir is kiosk-demo-atablefor
(renamed from / foodelivery, T-033). All others: kiosk-demo-<name>.`
569b02f ("scrub: remove private-workspace refs for publication, T-011") deleted
the private `T-033` reference and rewrote the 2nd line to `All apps:
kiosk-demo-<name>.`, leaving :14 dangling.
DECISION: delete :14. After the rename atablefor obeys the general rule on :15,
so the note has zero operational content, and the T- id it cited cannot be
republished (T-011).

## K-610 — deploy/README.md "Files in this directory" table
Add rows: CHECKLIST.md, demo-reset.sh, telemetry-init.sql, production-smoke.sh.
production-smoke.sh row must say: RAILS_ENV=production boot smoke for one demo
per unique HTML surface (stylish | prove); CI is its caller; NOT for a
deployment — it creates+DROPS `kiosk_<app>_smoke` and require_disposable_host()
refuses outright on a deploy host (K-594).

## K-615 — prune.sh prune half is a permanent no-op
DECISION: option (b) — the prune half goes; prune.sh survives as the honest
re-seed helper. Evidence for (b) over "write demo:prune per app":
 - Neither half has ever run: no demo defines `demo:prune` or `demo:seed`.
 - Both jobs are ALREADY covered: disk reclaim = deploy/demo-reset.sh (drop +
   fresh seed, Phil's DEMO-DATA-RESET decision, K-464); catalog re-seed = the
   post-receive hook runs `db:seed` on every push (K-464).
 - K-593 (Phil) recorded WHY retention is unnecessary: per-agent isolation makes
   a poker's junk invisible, disk is the only cost, hand-reseed if it matters.
 - So option (a) = 7 new DESTRUCTIVE production rake tasks + 7 CI matrix/ungated
   entries + 7 README task-table lines, feeding a cron deliberately not
   installed, duplicating a tool that already reclaims 100%.
 - `db:seed` is the verified-safe replacement for the fictional `demo:seed`:
   K-464 verified all 7 demo seeds idempotent-additive (0 delete_all) and it was
   run live on all 7; demo-reset.sh runs it on this box today.
CONSTRAINT: do NOT promote prune.sh to an installed step (K-593 SKIP stands).
DID NOT rename/delete prune.sh: K-593's fix text + CHECKLIST §7 record it
"stays in the repo as an available-but-uninstalled tool" — reversing that is
Phil's call. Reported as a recommendation instead.

## Remaining
- [ ] K-609 edit
- [ ] K-610 table
- [ ] K-615 prune.sh + README (:18, :88-89, :183-188, :351-353) + CHECKLIST §7
      + telemetry-init.sql:57 ("the prune cron may DELETE" — no such cron)
- [ ] CHANGELOG line
- [ ] gates: bash -n on touched scripts; prune.sh end-to-end with KIOSK_APPS_ROOT
- [ ] delete this file in the final commit
