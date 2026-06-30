# P4 T3 Progress Ledger — kiosk-demo-getgrocery

## Tasks

- [x] T3: scaffold kiosk-demo-getgrocery + happy path (register→add_to_cart→apply_substitution→confirm_delivery→pay)

## Entries

BASE commit: 10409c1

Task T3: complete (commits 10409c1..f8e5175, review clean — Important fixes applied: hostname + bin/demo adaptation + dead conn removed; open Minors: add_to_cart store validation, confirm_delivery hardcoded date, apply_substitution post-update SELECT guard)

---

# P6 getgrocery surface refactor — SDD Progress Ledger

BASE commit: 145e7b9 (feat/p6-getgrocery-surface branch)

## Tasks

- [x] Task A: Domain core (migration, models, kiosk.rb queries+actions, seeds, structure.sql)
- [x] Task B: Flow driver + rake (getgrocery_flow.rb, demo.rake demo:shop+schema+isolation+redteam)
- [x] Task C: Redteam + isolation (redteam_suite.rb, isolation_flow.rb + non-vacuity check)
- [x] Task D: Admin + docs (admin controller+view, KIOSK.skill.md, before-after.md)

## Entries

Task A: complete (commits 145e7b9..ad30ed4, review clean — Important fix applied: total_cents quoted via conn.quote)
Task B: complete (commits ad30ed4..ef621b0, review clean)
Task C: complete (commits ef621b0..1afdd9a, review clean — non-vacuity: PayForOtherUseSelf BREACH confirmed with Gate 1 ownership removed, GREEN after restore)
Task D: complete (commits 1afdd9a..5dd496a, review clean — Important fix: removed add_to_cart backreference from KIOSK.skill.md)
Final review: clean (commits 145e7b9..871ed44) — Minor fixes applied: removed spurious unit/status fields from docs
