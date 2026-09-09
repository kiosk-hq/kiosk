# frozen_string_literal: true

# `bundle exec rspec` for this demo, which is what an adopting operator on RSpec
# reaches for first. The Kiosk pieces are three lines and they are the whole of
# the wiring: require the engine-backed ORIGIN, require the RSPEC adapter, and
# hand the one to the other.
#
# The origin is what answers the four questions the conformance checks ask —
# which verbs does this app declare, what does its router say about them, what
# does a verb answer as a given principal, and does that answer satisfy the
# schema the verb published. It reads all four from the same places the running
# server does: the registry `config/initializers/kiosk.rb` populated through
# `c.handlers`, `Rails.application.routes`, the registered handler under a
# GUC-scoped session, and the engine's own response validator.
#
# The Minitest spelling is the same three lines with `conformance/minitest` in
# place of `conformance/rspec` — kiosk-demo-getgrocery is the worked example of
# that half.
#
# ── WHY `.rspec` NAMES A DEFAULT PATH ────────────────────────────────────────
#
# `spec/wire_arguments_spec.rb` beside this directory is NOT an RSpec file: it
# is a standalone Ruby assertion script with its own `assert` and its own exit
# block, run by `rake demo:wire_args_spec`. A bare `bundle exec rspec` over the
# whole of `spec/` would load it, define zero examples from it, and exit 0
# having asserted nothing this suite meant to assert. `--default-path
# spec/conformance` is what stops a green run from being a run that never
# happened.

ENV["RAILS_ENV"] ||= "test"

require_relative "../../config/environment"
require "rspec/rails"

require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/rspec"

Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!

  # `schema_format = :sql`, so the test database is loaded by
  # `rake demo:conformance` before this runs rather than by a Rails schema
  # check. Each example rolls back, so the fixtures below never accumulate.
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
end
