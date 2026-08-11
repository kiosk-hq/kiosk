# RESUME NOTE — T-052 (K-495 slice 1 of 6): make kiosk-server a Rails gem

Branch `railsgem-0811`. Owner scope: `kiosk-server/**` + the other gems'
gemspecs. NOT demos' lib/bin/spec/lib-tasks/READMEs, NOT deploy/**, NOT
.github/workflows/ci.yml.

## Baseline (before any edit)
`cd kiosk-server && bundle exec rspec` -> 880 examples, 0 failures.

## Evidence gathered (step 1 — what Rails surface the gem ACTUALLY uses)
Non-comment references in `kiosk-server/lib`:
- actionpack: `ActionController::API` (7 controllers), `ActionController::Base`
  (device_verify, assistants), `ActionController::InvalidAuthenticityToken`
  (rescue_from x2).
- railties: `Rails::Engine` (engine.rb), `Rails::Generators::Base` +
  `Rails::Generators::Migration` (lib/generators/kiosk/install), `Rails.logger`
  (pop_verifier).
- activerecord: `ActiveRecord::Base.connection` in account_binding (x2),
  agent_login, agent_registration, default_agent_idp (x5), column_spending_cap,
  wire_controller, device_authorization_stores; `ActiveRecord::RecordNotUnique`,
  `ActiveRecord::StatementInvalid`, `ActiveRecord::Migration[...]` in all 9
  generator migration templates.
- activesupport: `String#constantize` (agent_registration.rb:110),
  `String#classify` (generator initializer template).

NOT used anywhere: actionmailer, actioncable, activejob, activestorage,
actiontext, actionmailbox, activemodel (directly). => the `rails` meta-gem is
NOT honest; `railties + actionpack + activerecord + activesupport` is.

## Decisions taken
- Constraint `~> 8.1` for all four: demos + e2e run Rails 8.1.3, CI Ruby 4.0.1,
  the gemspec already had `railties "~> 8.1"` as a dev dep. Claiming 7.x would
  be an untested claim (rule 1). `required_ruby_version >= 3.2.0` already
  matches Rails 8.1's own floor.
- Declare the four component gems, NOT `rails` — this is Phil's "скромнее"
  option and it is TRUE.
- Delete the 10 `if defined?(...)` conditional-definition guards (9 controllers
  + engine.rb) and require the framework unconditionally; the two runtime
  `defined?(::ActiveRecord::Base)` guards (configuration_extension,
  test_executor) and the `defined?(::Rails)` logger guard (pop_verifier) become
  dead branches once active_record/rails are hard-required, so they collapse.

## NOT in this slice (leave for T-053..T-057)
- Do NOT mount the engine / fold routes into its drawer (K-505 -> T-055).
- Do NOT introduce Kiosk::Query / Kiosk::Action mixins (T-053).
- Do NOT touch the error taxonomy (T-054), generators' scaffolding (T-056),
  or the demos' initializers (T-057).

## Remaining
(see git log on this branch)
