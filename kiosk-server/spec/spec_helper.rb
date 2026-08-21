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
# `ApplicationController` the Kiosk::Handler specs include the mixin into. Kiosk imposes no superclass on operators (K-495: inheritance is
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

# ── Declaring a verb, the one way there is (T-081) ──────────────────────────
#
# A verb reaches the Actions/Queries registry through a controller that
# includes {Kiosk::Handler}, where class-level macros — `kind` among them — are
# claimed by the next `def`. These helpers build exactly that — an anonymous
# controller on the fake ApplicationController above — so a spec that needs
# "a registered query named X" gets one through the shipped shape rather than
# through a back door of its own.
#
# What that costs, and why it is the right price: a handler RENDERS, so its
# result makes a JSON round trip before the {Kiosk::Server::Executor} sees it,
# and symbol keys come back as strings. Specs assert the string keys — which
# is what an agent on the wire actually receives.
#
# The macros ARE the opt-in: a method declared with none of them is a helper
# the wire cannot see. So at least one is always passed, and `description:`
# is the default when a spec does not care which.
#
# @param name [String, Symbol] the wire name (also the controller method name)
# @param macros [Hash] descriptor macros — description:, input_schema:,
#   output_schema:, example_params:, example_row:
# @param body [Proc] the controller action; defaults to an empty render
# @return [Class] the handler controller, already registered
def declare_query(name, **macros, &body)
  declare_verb(:query, name, macros, body || -> { render json: [] })
end

def declare_action(name, **macros, &body)
  declare_verb(:action, name, macros, body || -> { render json: {} })
end

# The two REQUIRED declarations (T-073 = A), defaulted so a spec that is not
# about descriptors does not have to write them — and so that every verb these
# helpers build is one the mixin will actually accept, which is the point:
# since T-068 slice 3 a declaration missing either schema RAISES at class-body
# load. `output_schema true` is the "accepts anything" boolean schema, which is
# the honest declaration for a fixture that makes no claim about its shape;
# a spec that IS about the shape passes its own.
#
# The default `input_schema` is the OPEN object, not the closed empty one a
# real "takes nothing" verb declares: argument validation runs UNCONDITIONALLY
# on the per-verb wire now, so a closed default would 400 every fixture that
# passes an argument it never meant to constrain. A spec that is ABOUT the
# input contract declares its own closed schema, which is where the refusals
# are asserted.
DEFAULT_REQUIRED_MACROS = {
  input_schema:  { type: "object" },
  output_schema: true,
}.freeze

def declare_verb(verb_kind, name, macros, body)
  macros = { description: "the #{name} verb" } if macros.empty?
  macros = DEFAULT_REQUIRED_MACROS.merge(macros)

  Class.new(ApplicationController) do
    include Kiosk::Handler
    kind verb_kind
    macros.each { |macro, value| public_send(macro, value) }
    define_method(name.to_s, &body)
  end
end

# Minimal database-connection stub. Records every #execute call as a SQL
# string. Pretends to support transactions (yields the block, no rollback
# semantics — the real ActiveRecord::Base.connection.transaction handles
# rollback in production).
#
# `#exec_query` is the BIND-PARAMETER half of the same seam (K-654): the
# Executor's mandate/settlement statements carry `$1…$N` and hand their values
# alongside, so a fake that only recorded SQL text could no longer see them.
# Each call is recorded as `[sql, name, binds]` — the SQL to assert that no
# value was spliced into it, the binds to assert order and content. What this
# fake can NEVER assert is what Postgres makes of a bind's TYPE; that is
# `spec/kiosk/server/executor_persistence_spec.rb`'s job, against a real
# database.
class FakeConnection
  attr_reader :executed_sql, :exec_queries
  attr_accessor :next_result, :next_exec_result

  def initialize(next_result: [], next_exec_result: [{ "id" => "row-1" }])
    @executed_sql      = []
    @exec_queries      = []
    @next_result       = next_result
    @next_exec_result  = next_exec_result
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

  def exec_query(sql, name = "SQL", binds = [])
    @exec_queries << [sql, name, binds]
    @next_exec_result
  end

  def quote(value)
    "'#{value}'"
  end

  def quote_table_name(name) = name.split(".").map { |part| %("#{part}") }.join(".")

  def in_transaction? = @transaction_depth > 0

  # Every statement that carried a bind, as `[sql, binds]`, filtered by shape.
  # A spec asserts on BOTH halves: the text to prove no value was spliced into
  # it, the binds to prove order and content.
  def bound(pattern)
    exec_queries.select { |sql, _name, _binds| sql =~ pattern }
                .map { |sql, _name, binds| [sql, binds] }
  end

  # The whole statement text this fake ever saw, for "no value appears here"
  # assertions.
  def all_sql = (executed_sql + exec_queries.map(&:first)).join("\n")
end

# Route `FakeConnection#exec_query` by statement shape while keeping the fake's
# own recording, so a spec can say "the SELECT finds nothing, the INSERT returns
# this id" without re-implementing the recorder (and without a router silently
# dropping the binds the assertions need).
#
# @yieldparam sql [String]
# @yieldparam binds [Array]
# @yieldreturn [Array<Hash>] rows; production code calls `.to_a.first` on it
def route_exec_query(con, &router)
  allow(con).to receive(:exec_query) do |sql, name = "SQL", binds = []|
    con.exec_queries << [sql, name, binds]
    router.call(sql, binds)
  end
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
