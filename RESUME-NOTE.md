# RESUME-NOTE — K-622 (telemetry middleware re-dispatch + coverage)

Worktree `reference.telemetry-mw-0811`, branch `telemetry-mw-0811`.

## Task
K-622: `DemoTelemetryMiddleware#call`'s outer `rescue StandardError` wraps the
post-dispatch half and recovers with `@app.call(env)` → re-dispatches the whole
request. Fix in all SEVEN demo copies. Add real coverage (none exists).
K-623 side-task: reconcile the stale `:220` comment in the six non-getgrocery
copies (`schedule_delivery` → `reschedule_delivery`) if trivially correct.

## Decisions so far
- Test route: getgrocery has NO rspec; it ships plain-ruby DB-free specs in
  `spec/` driven by `demo:` rake tasks (`demo:slots_spec`, `demo:cashier_spec`).
  Follow that: `spec/telemetry_middleware_spec.rb` + task `demo:telemetry_spec`.
- Controller coverage via `rails runner` (routes are only drawn when
  KIOSK_TELEMETRY=1 at boot, so it needs its own boot).
- CI: add the new task to the getgrocery `tasks:` list in ci.yml, name it in
  README's hand-written list, then `bin/check-ci-tasks --write`.

## Status
- [ ] verify defect / red test
- [ ] fix (7 copies)
- [ ] green
- [ ] gates
