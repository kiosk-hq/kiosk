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

# Stand-in for the host application's base controller — the fake
# `ApplicationController` the Kiosk::Action / Kiosk::Query specs include the
# mixin into. Kiosk imposes no superclass on operators (K-495: inheritance is
# the operator's call), so its own specs must exercise the mixin against a base
# class it does not own.
#
# `protect_from_forgery` is here because every real Rails app installs it on
# ActionController::Base (config.action_controller.default_protect_from_forgery),
# and a handler sub-dispatch can never present a CSRF token — so the mixin has
# to skip it, and these specs have to prove it does.
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception
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

  def quote(value)
    "'#{value}'"
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
