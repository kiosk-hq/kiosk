# frozen_string_literal: true

require "kiosk/test_helpers"

# The four conformance checks, against a hand-built {NullOrigin}.
#
# Every example here is the shape of a real operator defect: a verb declared and
# never routed, a query routed POST, a handler that renders what its own
# output_schema rejects, a verb that hands one principal another's rows. The
# checks exist to make those red in an adopter's suite, so this file's job is to
# prove each one actually goes red — and, in the two places where a check could
# pass for the wrong reason, that it does not.
RSpec.describe Kiosk::TestHelpers::Conformance::Checks do
  # Short local names. Assigned as methods rather than as constants: a
  # constant assigned inside an example-group block lands on Object.
  def conformance = Kiosk::TestHelpers::Conformance
  def verb_class  = Kiosk::TestHelpers::Conformance::Verb
  def null_origin = Kiosk::TestHelpers::Conformance::NullOrigin

  # A catalogue-shaped query: array of objects, closed, two required fields.
  def catalog_verb(**overrides)
    verb_class.new(
      name: "catalog", kind: :query,
      input_schema:  { "type" => "object", "additionalProperties" => false,
                       "properties" => {}, "required" => [] },
      output_schema: { "type" => "array",
                       "items" => { "type" => "object", "additionalProperties" => false,
                                    "properties" => { "sku" => { "type" => "string" },
                                                      "price_cents" => { "type" => "integer" } },
                                    "required" => %w[sku price_cents] } },
      **overrides,
    )
  end

  def my_orders_verb(**overrides)
    verb_class.new(
      name: "my_orders", kind: :query,
      input_schema:  { "type" => "object", "additionalProperties" => false,
                       "properties" => {}, "required" => [] },
      output_schema: { "type" => "array", "items" => { "type" => "object" } },
      **overrides,
    )
  end

  def create_order_verb(**overrides)
    verb_class.new(
      name: "create_order", kind: :action,
      input_schema:  { "type" => "object", "additionalProperties" => false,
                       "properties" => { "sku" => { "type" => "string" } },
                       "required" => %w[sku] },
      output_schema: { "type" => "object", "properties" => { "order_id" => { "type" => "string" } },
                       "required" => %w[order_id] },
      example_params: { "sku" => "sourdough-bread" },
      **overrides,
    )
  end

  # ── 1. ROUTES ─────────────────────────────────────────────────────────────

  describe ".routes" do
    it "passes when every verb is routed with the method its kind requires" do
      origin  = null_origin.new(verbs: [catalog_verb, create_order_verb])
      outcome = described_class.routes(origin)

      expect(outcome).to be_ok
      expect(outcome.message).to include("all 2 declared verbs are routed under /kiosk/")
    end

    it "FAILS when a declared verb has no route at all — the T-183 bug class" do
      verbs  = [catalog_verb, create_order_verb]
      table  = null_origin.routes_for("/kiosk", verbs)
      table.delete(["POST", "/kiosk/create_order"])

      outcome = described_class.routes(null_origin.new(verbs: verbs, routes: table))

      expect(outcome).to be_failed
      expect(outcome.message).to include("nothing answers POST /kiosk/create_order")
      expect(outcome.message).to include("404 to every caller")
    end

    it "FAILS when a query is routed POST instead of GET" do
      verbs = [catalog_verb]
      table = { ["POST", "/kiosk/catalog"] => { controller: "kiosk/server/verb", action: "create",
                                                kiosk_verb: "catalog" } }

      outcome = described_class.routes(null_origin.new(verbs: verbs, routes: table))

      expect(outcome).to be_failed
      expect(outcome.message).to include("nothing answers GET /kiosk/catalog")
    end

    it "FAILS when a verb ALSO answers the other method on the verb wire" do
      verbs = [catalog_verb]
      table = null_origin.routes_for("/kiosk", verbs)
      table[["POST", "/kiosk/catalog"]] = { controller: "kiosk/server/verb", action: "create",
                                            kiosk_verb: "catalog" }

      outcome = described_class.routes(null_origin.new(verbs: verbs, routes: table))

      expect(outcome).to be_failed
      expect(outcome.message).to include("also reaches the verb wire on POST")
    end

    it "PASSES when the other method reaches the wire's refusal controller" do
      # The engine draws a catch-all refusal pair after the operator's routes,
      # so the wrong method resolving to `verb_refusal` is CORRECT — it is how
      # a 405 gets answered — and must not read as a double route.
      verbs = [catalog_verb]
      table = null_origin.routes_for("/kiosk", verbs)
      table[["POST", "/kiosk/catalog"]] = { controller: "kiosk/server/verb_refusal",
                                            action: "create", kiosk_verb: "catalog" }

      expect(described_class.routes(null_origin.new(verbs: verbs, routes: table))).to be_ok
    end

    it "FAILS with its own sentence when the engine's REFUSAL route caught the verb" do
      # The commonest spelling of «declared and never routed»: the engine
      # appends a single-segment refusal pair below the operator's routes, so a
      # verb nobody drew resolves to THAT rather than to nothing.
      verbs = [catalog_verb]
      table = { ["GET", "/kiosk/catalog"] => { controller: "kiosk/server/verb_refusal",
                                               action: "show", kiosk_verb: "catalog" } }

      outcome = described_class.routes(null_origin.new(verbs: verbs, routes: table))

      expect(outcome).to be_failed
      expect(outcome.message).to include("nothing you drew answers GET /kiosk/catalog")
      expect(outcome.message).to include("404 for a verb this origin publishes")
    end

    it "FAILS when a route reaches the handler controller directly" do
      verbs = [catalog_verb]
      table = { ["GET", "/kiosk/catalog"] => { controller: "kiosk/storefront", action: "catalog",
                                               kiosk_verb: "catalog" } }

      outcome = described_class.routes(null_origin.new(verbs: verbs, routes: table))

      expect(outcome).to be_failed
      expect(outcome.message).to include("bypasses authentication")
    end

    it "FAILS when the path segment and the kiosk_verb default disagree" do
      verbs = [catalog_verb]
      table = { ["GET", "/kiosk/catalog"] => { controller: "kiosk/server/verb", action: "show",
                                               kiosk_verb: "catalogue" } }

      outcome = described_class.routes(null_origin.new(verbs: verbs, routes: table))

      expect(outcome).to be_failed
      expect(outcome.message).to include("two spellings of one name")
    end

    it "VACUITY ARM: FAILS on an origin that declares no verbs at all" do
      outcome = described_class.routes(null_origin.new(verbs: []))

      expect(outcome).to be_failed
      expect(outcome.message).to include("declares no verbs at all")
    end
  end

  # ── 2. VERB EXECUTES ──────────────────────────────────────────────────────

  describe ".executes" do
    it "passes and reports the answer's shape" do
      origin  = null_origin.new(verbs: [catalog_verb],
                               answers: { "catalog" => [{ "sku" => "a", "price_cents" => 1 }] })
      outcome = described_class.executes(origin, :catalog)

      expect(outcome).to be_ok
      expect(outcome.message).to include("query \"catalog\" executed")
      expect(outcome.message).to include("1 row(s)")
    end

    it "uses the verb's own example_params when none are given, and says so" do
      origin  = null_origin.new(verbs: [create_order_verb],
                               answers: { "create_order" => { "order_id" => "x" } })
      outcome = described_class.executes(origin, :create_order)

      expect(outcome).to be_ok
      expect(outcome.message).to include("with its own example_params")
      expect(origin.calls.last[:params]).to eq({ "sku" => "sourdough-bread" })
    end

    it "reports a refusal with its wire code, message and hint" do
      refusal = Class.new(StandardError) do
        def code = "forbidden"
        def hint = "this verb only answers the order's owner"
      end.new("not yours")

      origin  = null_origin.new(verbs: [my_orders_verb], answers: { "my_orders" => refusal })
      outcome = described_class.executes(origin, :my_orders)

      expect(outcome).to be_failed
      expect(outcome.message).to include("did not execute")
      expect(outcome.message).to include("code=forbidden")
      expect(outcome.message).to include("hint: this verb only answers the order's owner")
    end

    it "names the declared verbs when asked for one that is not declared" do
      origin  = null_origin.new(verbs: [catalog_verb, create_order_verb])
      outcome = described_class.executes(origin, :catalogue)

      expect(outcome).to be_failed
      expect(outcome.message).to include("no verb named \"catalogue\"")
      expect(outcome.message).to include("Declared: catalog, create_order")
    end
  end

  # ── 3. THE DECLARED SHAPE ─────────────────────────────────────────────────

  describe ".declared_shape" do
    it "passes when the answer satisfies the verb's own output_schema" do
      origin = null_origin.new(
        verbs: [catalog_verb],
        answers: { "catalog" => [{ "sku" => "sourdough", "price_cents" => 449 }] },
      )

      expect(described_class.declared_shape(origin, :catalog)).to be_ok
    end

    it "FAILS when the handler renders a shape the descriptor rejects" do
      origin = null_origin.new(
        verbs: [catalog_verb],
        # `price_cents` as a formatted String — the commonest descriptor lie
        # there is, and one nothing on the wire would notice.
        answers: { "catalog" => [{ "sku" => "sourdough", "price_cents" => "4.49" }] },
      )
      outcome = described_class.declared_shape(origin, :catalog)

      expect(outcome).to be_failed
      expect(outcome.message).to include("rendered a payload its own output_schema rejects")
      expect(outcome.message).to include("/0/price_cents")
      expect(outcome.details[:stage]).to eq(:output)
    end

    it "FAILS on the ARGUMENTS separately, before executing anything" do
      origin  = null_origin.new(verbs: [create_order_verb],
                               answers: { "create_order" => { "order_id" => "x" } })
      outcome = described_class.declared_shape(origin, :create_order, params: { "sku" => 12 })

      expect(outcome).to be_failed
      expect(outcome.message).to include("do not satisfy")
      expect(outcome.message).to include("input_schema")
      expect(outcome.details[:stage]).to eq(:input)
      expect(origin.calls).to be_empty
    end

    it "FAILS rather than skipping when the verb declares no output_schema" do
      origin  = null_origin.new(verbs: [catalog_verb(output_schema: nil)])
      outcome = described_class.declared_shape(origin, :catalog)

      expect(outcome).to be_failed
      expect(outcome.message).to include("publishes no output_schema")
    end

    it "FAILS rather than skipping when the verb declares no input_schema" do
      origin  = null_origin.new(verbs: [catalog_verb(input_schema: nil)])
      outcome = described_class.declared_shape(origin, :catalog)

      expect(outcome).to be_failed
      expect(outcome.message).to include("publishes no input_schema")
    end

    it "delegates validation to an origin that brings its own checker" do
      origin = null_origin.new(verbs: [catalog_verb], answers: { "catalog" => [] })
      def origin.schema_errors(_payload, schema:, verb:, kind:, slot:)
        slot == "output_schema" ? ["(root): the engine's own checker said so"] : []
      end

      outcome = described_class.declared_shape(origin, :catalog)

      expect(outcome).to be_failed
      expect(outcome.message).to include("the engine's own checker said so")
    end
  end

  # ── 4. PRINCIPAL SCOPE ────────────────────────────────────────────────────

  describe ".principal_scope" do
    def scoped_origin(alice_rows:, bob_rows:, verb: my_orders_verb)
      null_origin.new(
        verbs:   [verb],
        answers: { [verb.name, :alice] => alice_rows, [verb.name, :bob] => bob_rows },
      )
    end

    it "passes when the second principal sees none of the first's rows" do
      origin = scoped_origin(alice_rows: [{ "order_id" => "a1" }],
                             bob_rows:   [{ "order_id" => "b1" }])
      outcome = described_class.principal_scope(origin, :my_orders, as: :alice, and_not: :bob)

      expect(outcome).to be_ok
      expect(outcome.message).to include("none of which reached :bob")
    end

    it "FAILS when a row leaks across principals" do
      leaked = { "order_id" => "a1", "total_cents" => 500 }
      origin = scoped_origin(alice_rows: [leaked], bob_rows: [leaked, { "order_id" => "b1" }])

      outcome = described_class.principal_scope(origin, :my_orders, as: :alice, and_not: :bob)

      expect(outcome).to be_failed
      expect(outcome.message).to include("leaked 1 row(s) belonging to :alice")
    end

    it "VACUITY ARM: FAILS when the first principal sees nothing" do
      # The trap this arm exists for: a verb that answers EVERYBODY with
      # nothing satisfies "bob sees none of alice's rows" vacuously, and the
      # naive spelling of this assertion goes green on a broken verb.
      origin  = scoped_origin(alice_rows: [], bob_rows: [])
      outcome = described_class.principal_scope(origin, :my_orders, as: :alice, and_not: :bob)

      expect(outcome).to be_failed
      expect(outcome.message).to include("no positive control")
    end

    it "FAILS on a verb declared reach: published, naming the declared reach" do
      origin  = scoped_origin(alice_rows: [{ "id" => 1 }], bob_rows: [{ "id" => 1 }],
                              verb: my_orders_verb(reach: "published"))
      outcome = described_class.principal_scope(origin, :my_orders, as: :alice, and_not: :bob)

      expect(outcome).to be_failed
      expect(outcome.message).to include("reach: :published")
      expect(outcome.message).to include("asserts the opposite of the descriptor")
    end

    it "PASSES when the second principal is REFUSED outright" do
      # Refusing is the stronger spelling of scoping: an origin that answers 404
      # to a row it will not show does not even confirm the row exists. This is
      # the shape a real demo hit — getgrocery's `kyc_status` answers
      # `not_found` to a principal polling somebody else's request id.
      refusal = Class.new(StandardError) do
        def code = "not_found"
        def http_status = 404
      end.new("no such verification request for this principal")

      origin = null_origin.new(
        verbs:   [my_orders_verb],
        answers: { ["my_orders", :alice] => [{ "order_id" => "a1" }],
                   ["my_orders", :bob]   => refusal },
      )
      outcome = described_class.principal_scope(origin, :my_orders, as: :alice, and_not: :bob)

      expect(outcome).to be_ok
      expect(outcome.message).to include("REFUSED :bob outright (404 not_found)")
    end

    it "still FAILS when the second principal's call breaks rather than refuses" do
      # A 500 is a defect in the handler and a 400 is a defect in the test's own
      # arguments. Neither is scoping, and reading either as a pass is how this
      # check would go green on a verb nobody can call.
      broken = Class.new(StandardError) do
        def code = "action_failed"
        def http_status = 500
      end.new("undefined method for nil")

      origin = null_origin.new(
        verbs:   [my_orders_verb],
        answers: { ["my_orders", :alice] => [{ "order_id" => "a1" }],
                   ["my_orders", :bob]   => broken },
      )
      outcome = described_class.principal_scope(origin, :my_orders, as: :alice, and_not: :bob)

      expect(outcome).to be_failed
      expect(outcome.message).to include("did not execute")
    end

    it "FAILS when the FIRST principal is refused their own rows" do
      refusal = Class.new(StandardError) do
        def code = "forbidden"
        def http_status = 403
      end.new("not yours")

      origin = null_origin.new(
        verbs:   [my_orders_verb],
        answers: { ["my_orders", :alice] => refusal, ["my_orders", :bob] => [] },
      )
      outcome = described_class.principal_scope(origin, :my_orders, as: :alice, and_not: :bob)

      expect(outcome).to be_failed
      expect(outcome.message).to include("did not execute")
    end

    it "treats an action's single object as one row" do
      origin = null_origin.new(
        verbs:   [create_order_verb],
        answers: { ["create_order", :alice] => { "order_id" => "a1" },
                   ["create_order", :bob]   => { "order_id" => "b1" } },
      )

      expect(
        described_class.principal_scope(origin, :create_order, as: :alice, and_not: :bob),
      ).to be_ok
    end
  end

  # ── Wiring ────────────────────────────────────────────────────────────────

  describe "the origin seam" do
    it "raises a wiring hint when no origin is configured" do
      expect { conformance.routes }
        .to raise_error(Kiosk::TestHelpers::Errors::OriginNotConfigured, /ConformanceOrigin/)
    end

    it "runs the checks against the configured origin" do
      conformance.origin = null_origin.new(verbs: [catalog_verb])

      expect(conformance.routes).to be_ok
    end
  end
end
