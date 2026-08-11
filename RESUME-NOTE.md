# RESUME-NOTE (branch ci-complete-0811) — delete before the branch lands

K-617 (hoteling demo:browse ungated), K-618 (atablefor demo:walkthrough ungated),
K-619 (publish + enforce the CI task set).

## Measured (done)
- hoteling `demo:browse` at CI-default low (n=96 k=5): **6.85 s wall-clock total,
  exit 0**, curve [0,0,0,1,2,3,4] = 10 browse proofs + 1 register proof.
  AFFORDABLE -> wire it. Proof-of-failure: HOTELING_FREE_BROWSES 3->99 =>
  curve all zeros, "FAIL browsing never got priced", exit 1. Reverted.
- atablefor `demo:walkthrough`: **3.81 s, exit 0**. Proof-of-failure (unique to
  it): db/seeds.rb WALKTHROUGH_STUB_USER_ID ...0001 -> ...000f => book_table
  FK violation, "did not return a value.booking_id", exit 1 — while `demo:book`
  under the SAME break stays exit 0. Reverted.

## K-619 mechanism (script written, wiring pending)
`bin/check-ci-tasks` (stdlib, no bundle):
 - parses ci.yml demos matrix `tasks:` + a new per-entry `ungated:` map
   (task -> reason), and each demo's `demo:` tasks from lib/tasks/*.rake
 - fails on: task in neither / stale or reasonless opt-out / opt-out that is
   also gated / ci.yml task the demo does not define / demo dir with no entry
 - `--write` regenerates a "Which of these run in CI" table between
   CI-TASKS:BEGIN/END markers in each demo README; without --write it CHECKS it
 - `--verify-inventory DIR` cross-checks the static parse against `bin/rails -AT`
   (runs inside the demos job, where the bundle exists)

First run reproduced the full gap set by itself, including **demo:telemetry**
(getgrocery) which no row had recorded.

## Remaining
- [ ] ci.yml: wire demo:walkthrough (atablefor, LAST — it reseeds) and
      demo:browse (hoteling, LAST — it reseeds); add `ungated:` maps
- [ ] README CI-TASKS markers x8 + --write
- [ ] new CI job running bin/check-ci-tasks + per-demo --verify-inventory step
- [ ] prove the check catches a deliberately unwired task
- [ ] CHANGELOG line; self-gate (full task lists of atablefor + hoteling,
      zeitwerk:check on both, yaml load)
