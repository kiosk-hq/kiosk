# frozen_string_literal: true

require "kiosk/server/conformance_origin"

# The engine-backed ORIGIN, and the four conformance checks running against a
# REAL registry rather than a hand-built one.
#
# The point of these examples is the seam, not the checks — those are covered
# where they live, in kiosk-test-support. What has to be true here is that the
# four questions the checks ask get answered from the same sources the running
# server answers them from: the verb registry the mixin populated, the route
# table Rails dispatches on, the registered handler under a GUC-scoped session,
# and the engine's own schema validator.
RSpec.describe Kiosk::Server::ConformanceOrigin do
  # A route table with `recognize_path`'s contract: it RAISES for a path with
  # no route, which is what makes "nothing answers" different from "answers
  # something else".
  class FakeRouteSet
    def initialize(table) = @table = table

    def recognize_path(path, method:)
      @table.fetch([method.to_s.upcase, path]) do
        raise ActionController::RoutingError, "No route matches #{method.upcase} #{path}"
      end
    end
  end

  # Records the transaction and the GUC binds, so an example can assert the
  # call really ran inside a session context.
  class RecordingConnection
    attr_reader :exec_queries, :transactions_opened

    def initialize
      @exec_queries        = []
      @transactions_opened = 0
    end

    def transaction
      @transactions_opened += 1
      yield
    end

    def exec_query(sql, name = "SQL", binds = [])
      @exec_queries << [sql, name, binds]
      []
    end
  end

  let(:connection) { RecordingConnection.new }
  let(:alice)      { Struct.new(:id, :role).new("u-alice", "customer") }
  let(:bob)        { Struct.new(:id, :role).new("u-bob", "customer") }

  def origin(routes: nil)
    described_class.new(connection: connection, routes: routes)
  end

  def wired_routes(*names_and_kinds)
    table = names_and_kinds.each_with_object({}) do |(name, kind), out|
      query  = kind.to_sym == :query
      method = query ? "GET" : "POST"
      action = query ? "show" : "create"
      out[[method, "/kiosk/#{name}"]] =
        { controller: "kiosk/server/verb", action: action, kiosk_verb: name }
    end
    FakeRouteSet.new(table)
  end

  describe "#verbs" do
    it "reads BOTH registries, with each verb's kind, reach and schemas" do
      declare_query("menu", reach: :published, output_schema: { type: "array" })
      declare_action("order", output_schema: { type: "object" })

      verbs = origin.verbs

      expect(verbs.map(&:name)).to contain_exactly("menu", "order")
      expect(verbs.find { |v| v.name == "menu" }).to have_attributes(
        kind: :query, reach: "published", output_schema: { type: "array" },
      )
      # `reach` defaults to principal and is spelled nowhere in a declaration
      # that means it — which is why the descriptor publishes it anyway.
      expect(verbs.find { |v| v.name == "order" }.reach).to eq("principal")
    end

    it "is rebuilt on every call, so a verb removed from the registry disappears" do
      declare_query("menu")
      subject_origin = origin
      expect(subject_origin.verbs.map(&:name)).to eq(["menu"])

      Kiosk::Server::Queries.unregister("menu")

      expect(subject_origin.verbs).to be_empty
    end
  end

  describe "#recognize" do
    it "reports what the router says" do
      routes = wired_routes(%w[menu query])

      expect(origin(routes: routes).recognize("/kiosk/menu", method: "GET"))
        .to eq(controller: "kiosk/server/verb", action: "show", kiosk_verb: "menu")
    end

    it "answers nil — not an error — when nothing is routed there" do
      expect(origin(routes: wired_routes).recognize("/kiosk/menu", method: "GET")).to be_nil
    end
  end

  describe "#call" do
    it "runs the handler inside a GUC-scoped transaction as the named principal" do
      declare_query("mine") { render json: [{ user: kiosk_identity.user_id }] }

      answer = origin.call("mine", kind: :query, params: {}, as: alice)

      expect(answer).to eq([{ "user" => "u-alice" }])
      expect(connection.transactions_opened).to eq(1)
      expect(connection.exec_queries.map { |(_, _, binds)| binds })
        .to include(["app.current_user_id", "u-alice"])
    end

    it "takes the role from the subject when it has one" do
      declare_query("mine") { render json: [{ role: kiosk_identity.role }] }

      expect(origin.call("mine", kind: :query, params: {}, as: bob)).to eq([{ "role" => "customer" }])
    end

    it "accepts a bare principal id, so a test needs no fixture row" do
      declare_query("mine") { render json: [{ user: kiosk_identity.user_id }] }

      expect(origin.call("mine", kind: :query, params: {}, as: "synthetic:carol"))
        .to eq([{ "user" => "synthetic:carol" }])
    end

    it "validates arguments against input_schema first, as the wire does" do
      declare_query("search",
                    input_schema: { type: "object", properties: { limit: { type: "integer" } },
                                    required: %w[limit] }) { render json: [] }

      expect { origin.call("search", kind: :query, params: { limit: "many" }, as: alice) }
        .to raise_error(Kiosk::Server::Errors::BadRequest)
    end

    it "unwraps a paginated answer to its rows, which is what a caller receives" do
      declare_query("paged") do
        render_kiosk_page([{ id: 1 }], next_cursor: "opaque")
      end

      expect(origin.call("paged", kind: :query, params: {}, as: alice)).to eq([{ "id" => 1 }])
    end

    it "refuses an anonymous call, naming why there is no such thing" do
      declare_query("mine")

      expect { origin.call("mine", kind: :query, params: {}, as: nil) }
        .to raise_error(ArgumentError, /needs a principal/)
    end
  end

  describe "#schema_errors" do
    it "is the ENGINE's own validator, so a test and a running server agree" do
      errors = origin.schema_errors(
        [{ "price_cents" => "4.49" }],
        schema: { type: "array",
                  items: { type: "object", properties: { price_cents: { type: "integer" } } } },
        verb: "catalog", kind: :query, slot: "output_schema",
      )

      expect(errors.length).to eq(1)
      expect(errors.first).to include("output_schema:")
      expect(errors.first).to include("rendered a payload its own output_schema rejects")
      expect(errors.first).to include("/0/price_cents")
    end

    it "checks ARGUMENTS with the REQUEST validator, so a reserved name is exempt" do
      # `limit` and `cursor` are wire-reserved and always accepted, so a verb
      # whose closed input_schema does not declare `limit` still takes one — and
      # a conformance check that validated against the bare schema would reject
      # an example the wire accepts. Measured on a real demo whose
      # `example_params` publishes exactly that.
      closed = { type: "object", additionalProperties: false,
                 properties: { neighbourhood: { type: "string" } }, required: [] }

      expect(origin.schema_errors({ neighbourhood: "Beşiktaş", limit: 20 },
                                  schema: closed, verb: "search_hotels", kind: :query,
                                  slot: "input_schema")).to eq([])
    end

    it "still reports an argument the input_schema really rejects" do
      closed = { type: "object", additionalProperties: false,
                 properties: { neighbourhood: { type: "string" } }, required: [] }

      errors = origin.schema_errors({ neighbourhood: 5 }, schema: closed, verb: "search_hotels",
                                    kind: :query, slot: "input_schema")

      expect(errors.length).to eq(1)
      expect(errors.first).to start_with("input_schema:")
    end

    it "is empty when the payload satisfies the declaration" do
      expect(origin.schema_errors([], schema: { type: "array" }, verb: "catalog",
                                  kind: :query, slot: "output_schema")).to eq([])
    end
  end

  describe "the four checks, against a real registry" do
    before { Kiosk::TestHelpers::Conformance.origin = origin(routes: routes) }

    after { Kiosk::TestHelpers::Conformance.reset! }

    let(:routes) { wired_routes(%w[catalog query], %w[my_orders query], %w[place_order action]) }

    def declare_the_fleet
      declare_query("catalog",
                    input_schema:  { type: "object", properties: {} },
                    output_schema: { type: "array",
                                     items: { type: "object",
                                              properties: { sku: { type: "string" } },
                                              required: %w[sku] } }) do
        render json: [{ sku: "sourdough" }]
      end
      declare_query("my_orders",
                    input_schema:  { type: "object", properties: {} },
                    output_schema: { type: "array" }) do
        render json: [{ order_id: "o-#{kiosk_identity.user_id}" }]
      end
      declare_action("place_order",
                     input_schema:  { type: "object", properties: {} },
                     output_schema: { type: "object" }) { render json: { ok: true } }
    end

    it "passes all four on a conforming origin" do
      declare_the_fleet

      expect(Kiosk::TestHelpers::Conformance.routes).to be_ok
      expect(Kiosk::TestHelpers::Conformance.executes("catalog", as: alice)).to be_ok
      expect(Kiosk::TestHelpers::Conformance.declared_shape("catalog", as: alice)).to be_ok
      expect(Kiosk::TestHelpers::Conformance.principal_scope("my_orders", as: alice, and_not: bob))
        .to be_ok
    end

    it "reddens on a verb that is declared and never routed" do
      declare_the_fleet
      declare_query("forgotten")

      outcome = Kiosk::TestHelpers::Conformance.routes

      expect(outcome).to be_failed
      expect(outcome.message).to include("nothing answers GET /kiosk/forgotten")
    end

    it "reddens on a handler whose answer its own output_schema rejects" do
      declare_query("catalog",
                    input_schema:  { type: "object", properties: {} },
                    output_schema: { type: "array",
                                     items: { type: "object",
                                              properties: { price_cents: { type: "integer" } },
                                              required: %w[price_cents] } }) do
        render json: [{ price_cents: "4.49" }]
      end

      outcome = Kiosk::TestHelpers::Conformance.declared_shape("catalog", as: alice)

      expect(outcome).to be_failed
      expect(outcome.message).to include("output_schema")
    end

    it "reddens on a handler that answers every principal the same rows" do
      declare_query("my_orders",
                    input_schema:  { type: "object", properties: {} },
                    output_schema: { type: "array" }) { render json: [{ order_id: "everybody" }] }

      outcome = Kiosk::TestHelpers::Conformance.principal_scope("my_orders", as: alice, and_not: bob)

      expect(outcome).to be_failed
      expect(outcome.message).to include("leaked")
    end
  end
end
