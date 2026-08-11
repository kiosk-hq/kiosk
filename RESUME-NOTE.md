# RESUME NOTE — dup-guard-0811 (T-060)

Task: K-623 / K-607 / K-624 / K-616. Build a GUARD (not a one-off sync) for
application code hand-copied across the demos, wire it into CI like
`bin/check-ci-tasks`, close the six-demo telemetry coverage asymmetry, and give
`demo:reconcile` a gate/utility signpost outside ci.yml.

Owned here: demos' `lib/`, `bin/`, `spec/`, `lib/tasks/`, demo READMEs,
`.github/workflows/ci.yml`. NOT owned: `deploy/**`, `kiosk-server/**`.

## Measured facts (this tree, 2026-08-11)

Scan roots `kiosk-demo-*/{lib,app,script,db/migrate}/**/*.rb` (minus lib/tasks):
37 relative paths exist in >= 2 demos. Byte-identical: demo_telemetry,
demo_activity_controller, pow_difficulty, users/sessions_controller,
application_job, 10 db/migrate files. Identical-modulo-comments/whitespace:
application_controller, kyc_callback_controller, application_record,
kyc_verification_request, create_users migration, jwt_or_stub_idp, stub_idp,
stub_psp, prove_broker_client. Genuinely divergent: uuid_check (getgrocery adds
JSON_SCHEMA_PATTERN), stub_user_idp (stylish is a DB-backed staff IdP),
prove_trust + prove_broker_boot (operator id baked in), home_controller,
user.rb, booking.rb, all script/*.rb.
Drift found: `lib/equihash_register.rb` — skooti+tudu call the constant
`SOLVE_PY`, atablefor/getgrocery/hoteling `EQUIHASH_REGISTER_SOLVE_PY`
(renamed in dbeeb97 for 3 of 5 copies only). Contained to that file
(grep: no other reference); file is in every demo's autoload_lib ignore list.

## Plan / progress

1. [ ] `bin/check-demo-copies` — manifest + rules identical/code/per_demo,
       `except:` with reasons, plus the telemetry wiring assertion.
2. [ ] rename SOLVE_PY -> EQUIHASH_REGISTER_SOLVE_PY in skooti + tudu.
3. [ ] correct the false "byte-identical copy" claim in the 5 non-getgrocery
       uuid_check headers; point them at the guard.
4. [ ] ci.yml job `demo-file-sync`.
5. [ ] K-616: one line in getgrocery `demo:reconcile`'s DESC.
6. [ ] CHANGELOG line.
7. [ ] injected-divergence proof + gates, delete this file in the last commit.
