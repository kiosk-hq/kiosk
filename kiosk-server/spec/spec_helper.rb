# frozen_string_literal: true

require "kiosk/server"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.warnings = false

  config.before(:each) do
    Kiosk.reset!
    Kiosk::Server::Actions.reset!
    Kiosk::Server::Queries.reset!
  end
end

# Minimal database-connection stub. Records every #execute call as a SQL
# string. Pretends to support transactions (yields the block, no rollback
# semantics — the real ActiveRecord::Base.connection.transaction handles
# rollback in production).
class FakeConnection
  attr_reader :executed_sql
  attr_accessor :next_result

  def initialize(next_result: [])
    @executed_sql = []
    @next_result  = next_result
    @transaction_depth = 0
  end

  def transaction
    @transaction_depth += 1
    yield
  ensure
    @transaction_depth -= 1
  end

  def execute(sql)
    @executed_sql << sql
    @next_result
  end

  def in_transaction? = @transaction_depth > 0
end

# Build a valid Kiosk::Identity for testing. Defaults to an agent so the
# four GUCs are exercised; pass `actor:` to switch.
def build_identity(actor: "agent", **overrides)
  defaults = {
    user_id:  "u-1",
    role:     "customer",
    actor:    actor,
    agent_id: actor == "agent" ? "a-1" : nil,
    claims:   {},
  }
  Kiosk::Identity.new(**defaults.merge(overrides))
end
