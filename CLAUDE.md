# kiosk reference implementation — constitution

This repo is the Kiosk OSS monorepo: core gems (`kiosk-core`, `kiosk-server`,
`kiosk-all`, `kiosk-test-support`), opt-in RLS (`kiosk-rls`, `-rspec`,
`-minitest`), adapters (`kiosk-pay-stripe`, `kiosk-user-idp-devise`), PoW
(`kiosk-pow-equihash` — default, n=168 k=7; `kiosk-pow` — Argon2id legacy;
`kiosk-pow-cuckoo`), security (`kiosk-reputation`, `kiosk-redteam`), five
demo Rails apps (`kiosk-demo-*`), and the `e2e/` harness. Gem table:
`README.md`.

This repo will eventually be PUBLIC. Shipped content (code, READMEs) must
not depend on private material (meta/, umbrella files); the pointers below
serve the private development phase and are scrubbed before publication
(workspace T-011).

Part of the Kiosk workspace — the workspace constitution binds here. Paths
below are absolute on purpose: worktree checkouts live outside the umbrella.

- Workspace root: `/Users/pirj/source/kiosk` — `GOAL.md`, `PLAN.md`, `ARCHITECTURE.md`
- Findings ledger (record ALL discrepancies here): `/Users/pirj/source/kiosk/findings.md`
- Planned work: `/Users/pirj/source/kiosk/TODO.md`
- Normative spec: `/Users/pirj/source/kiosk/kiosk.tech/specification.html` · agent skill: `/Users/pirj/source/kiosk/kiosk.tech/skill.md`
- ADRs: `/Users/pirj/source/kiosk/meta/docs/adr/`

## The five rules

1. **Authority chain.** The spec (`kiosk.tech/specification.html`) is
   normative. Code and skill conform to the spec; landing/HN/README claim
   only what the code demonstrably does. An ADR may override the spec — then
   the spec must be updated to match.
2. **Conflict rule.** On a conflict with no recorded decision (ADR or a
   ledger `decision`): do NOT pick a side. Record it in the findings ledger
   as `decision-needed` and skip that item.
3. **Scope rule.** Found a problem outside your current task? Record it in
   the findings ledger. Do not fix it inline.
4. **Merge gate.** Tests covering the change must be green before merge; for
   `reference` that means the touched gem's own suite + `e2e/run.sh`.
5. **Changelog rule.** Significant changes — anything altering behavior, spec
   text, skill instructions, or claims — get ONE line in the touched repo's
   `CHANGELOG.md`: 1–2 sentences stating the essence and intent of the
   change, not its content. Tests-only changes, refactors, typos do not
   qualify.

## Repo specifics

- Ruby 4.0.1 (`.mise.toml`); per-gem bundles: `cd <gem> && bundle install &&
  bundle exec rspec` (`kiosk-rls-minitest`: `bundle exec rake test`).
- Demos: `bin/rails demo:setup`, then the flow tasks
  (`demo:walkthrough`/`shop`/`book`/`rideflow`, `demo:isolation`,
  `demo:redteam`). Postgres required.
- Full e2e: `./e2e/run.sh` (Postgres + jq). CI: `.github/workflows/ci.yml`
  (gems matrix + demos matrix + e2e).
- Inline `TODO`/`FIXME` must reference a `K-`/`T-` ID from the workspace
  ledgers; orphans become findings.
