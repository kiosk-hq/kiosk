# frozen_string_literal: true

# `include Kiosk::Handler` — the operator-facing seam
# (T-053, K-495 slice 2).
#
# Written from the CONSUMER's side: the controllers below are what an operator
# writes, and every assertion goes through a real path — the wire controller for
# the end-to-end ones, {Kiosk::Server::Executor} for the rest. Nothing calls the
# mixin's internals.
#
# `ApplicationController` (spec_helper.rb) is the fake Phil asked for: a
# stand-in for the host app's base class, carrying `protect_from_forgery`
# because every real Rails app does.

require "rack/mock"
require "uri"
require "json"

# An operator's OWN base class — the shape K-495 describes and T-056 will
# scaffold. Kiosk imposes neither this class nor its superclass; it only
# supplies the module included here. It declares no verbs and has no kind of
# its own: since K-921 the kind is a property of each DECLARATION, so there is
# nothing for a subclass to inherit but the macros.
class SpecKioskBaseController < ApplicationController
  include Kiosk::Handler
end

class SpecCatalogController < SpecKioskBaseController
  kind :query
  description "Lists what the shop has in stock right now, so the assistant " \
              "can decide what to put in a basket."
  input_schema type: "object", additionalProperties: false,
               properties: { q: { type: "string" } }
  output_schema type: "array",
                items: { type: "object",
                         properties: { sku: { type: "string" }, price_cents: { type: "integer" } } }
  example_params({ q: "milk" })
  example_row({ sku: "MILK-1L", price_cents: 199 })
  def catalog
    rows = [{ "sku" => "MILK-1L", "price_cents" => 199 }, { "sku" => "OATS-500G", "price_cents" => 249 }]
    rows = rows.select { |r| r["sku"].downcase.include?(params[:q].to_s.downcase) } if params[:q]
    render json: rows
  end

  kind :query
  description "Lists the caller's own orders, one page at a time."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def my_orders
    render_kiosk_page([{ "order_id" => "o-1", "for" => kiosk_identity&.user_id }],
                      next_cursor: Kiosk::Server::Cursor.encode_offset(1))
  end

  kind :query
  description "Reports who the wire says is calling."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def whoami
    render json: { user_id: kiosk_identity&.user_id, agent_id: kiosk_identity&.agent_id,
                   wire_name: kiosk_wire_name, user_agent: request.headers["User-Agent"] }
  end

  # No macros: a plain helper, NOT a wire verb.
  def not_a_verb
    render json: { reached: true }
  end
end

class SpecOrdersController < ApplicationController
  include Kiosk::Handler

  kind :action
  description "Places an order for the assistant's human. Nothing is charged " \
              "until the cart is settled with `pay`."
  input_schema type: "object", properties: { items: { type: "array" } }, required: %w[items]
  # The Ruby method is `place`; agents call it `create_order`.
  wire_name "create_order"
  output_schema true
  def place
    items = params[:items]
    if items.blank?
      return render json: { error: "at least one item is required",
                            hint: "pass items: [{sku:, quantity:}]" }, status: :bad_request
    end

    render json: { order_id: "o-1", item_count: items.size, for: kiosk_identity&.user_id }
  end

  kind :action
  description "Refuses, to show a policy refusal reaching the wire as forbidden."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def cancel_everything
    render json: { error: "assistants may not cancel every order at once" }, status: :forbidden
  end

  kind :action
  description "Raises the wire error whose code no HTTP status can carry."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def request_kyc
    raise Kiosk::Server::Errors::KycRequired, "attestation missing: over_18"
  end

  kind :action
  description "Blows up, to show an unhandled exception is not a silent 200."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def explode
    raise "boom"
  end
end

# ONE CONTROLLER, BOTH KINDS (K-921). The read and the write of the same
# resource sit together and the wire reaches each by its own HTTP method — the
# thing the retired Kiosk::Query/Kiosk::Action split made impossible to write.
class SpecBoardController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "Browse the board."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def board_listings
    render json: [{ "listing_id" => "l-1", "for" => kiosk_identity&.user_id }]
  end

  kind :action
  description "Post to the same board this class also reads."
  input_schema type: "object", additionalProperties: false,
               properties: { title: { type: "string" } }, required: %w[title]
  output_schema true
  def post_to_board
    render json: { "listing_id" => "l-2", "title" => params[:title] }
  end
end

# The three DECLARED DEPARTURES of spec §7.2 (K-949, ADR-0028), one verb each,
# so the reach vocabulary is exercised here and not only where a demo happens to
# use it. `:role` in particular has exactly one user in the fleet (stylish's
# salon_calendar) and would otherwise be a value nothing pins.
class SpecReachController < SpecKioskBaseController
  kind :query
  reach :published
  description "The open board — every principal's rows, published by the operator on purpose."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def open_board = render(json: [])

  kind :query
  reach :consented
  description "A shared list — reachable because a membership says so."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def shared_list = render(json: [])

  kind :action
  reach :role
  description "The staff book — how far it reaches depends on the caller's operator-assigned role."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def staff_book = render(json: {})
end

RSpec.describe "Kiosk::Handler (the operator mixin)" do
  let(:identity) { build_identity(user_id: "u-1", agent_id: "a-1") }
  let(:connection) { FakeConnection.new }

  # The class bodies above registered as they were read; spec_helper resets the
  # registries before every example, so put them back.
  before do
    [SpecCatalogController, SpecOrdersController, SpecBoardController,
     SpecReachController].each(&:kiosk_register!)
  end

  # The REAL dispatch path, minus HTTP: exactly what VerbController calls.
  # The wire NAME is an argument of its own — it is a path segment on the 0.4
  # wire, never a body field — so it is lifted out of `args` here the way the
  # controller lifts it out of `params[:kiosk_verb]`.
  def execute(kind, args)
    args = args.dup
    name = (args.delete(:name) || args.delete("name")).to_s
    Kiosk::Server::CurrentRequest.with(identity: identity) do
      Kiosk::Server::Executor.call(kind: kind, args: args, identity: identity,
                                   connection: connection, name: name.empty? ? nil : name)
    end
  end

  describe "declaring verbs" do
    it "registers each decorated method under its wire name" do
      expect(Kiosk::Server::Queries.known).to include("catalog", "my_orders", "whoami")
      expect(Kiosk::Server::Actions.known).to include("create_order")
    end

    it "does not register a method that carries no declarations" do
      expect(Kiosk::Server::Queries.known).not_to include("not_a_verb")
    end

    it "registers under the declared wire_name, not the Ruby method name" do
      expect(Kiosk::Server::Actions.known).to include("create_order")
      expect(Kiosk::Server::Actions.known).not_to include("place")
    end

    it "carries the macros into the descriptor the schema verb publishes" do
      descriptor = Kiosk::Server::Queries.describe("catalog")

      expect(descriptor[:description]).to start_with("Lists what the shop has in stock")
      expect(descriptor[:input_schema]).to eq(
        type: "object", additionalProperties: false, properties: { q: { type: "string" } },
      )
      expect(descriptor[:output_schema][:type]).to eq("array")
      expect(descriptor[:example_params]).to eq(q: "milk")
      expect(descriptor[:example_row]).to eq(sku: "MILK-1L", price_cents: 199)
    end

    it "omits params — retired by ADR-0023, and the mixin has no macro for it" do
      expect(Kiosk::Server::Queries.describe("catalog")[:params]).to be_nil
    end

    it "reaches the wire catalog the public `schema` endpoint serves" do
      document = Kiosk::Server::SchemaDocument.document

      expect(document[:queries].map { |d| d[:name] }).to include("catalog")
      expect(document[:actions].map { |d| d[:name] }).to include("create_order")
    end

    it "lets an operator's own base class carry the include, subclasses declare" do
      expect(SpecKioskBaseController.kiosk_declarations).to be_empty
      expect(SpecCatalogController.kiosk_declarations["catalog"][:kind]).to eq(:query)
    end

    # ── K-949 / ADR-0028: `reach`, the declared departure from §7.2 ──────
    it "publishes reach: principal for a verb that declares none — silence is the STRICT claim" do
      expect(Kiosk::Server::Queries.describe("catalog")[:reach]).to eq("principal")
      expect(Kiosk::Server::Actions.describe("create_order")[:reach]).to eq("principal")
    end

    it "publishes each declared departure verbatim on the descriptor" do
      expect(Kiosk::Server::Queries.describe("open_board")[:reach]).to eq("published")
      expect(Kiosk::Server::Queries.describe("shared_list")[:reach]).to eq("consented")
      expect(Kiosk::Server::Actions.describe("staff_book")[:reach]).to eq("role")
    end

    it "carries reach onto the wire catalog the public `schema` endpoint serves" do
      document = Kiosk::Server::SchemaDocument.document
      reaches  = (document[:queries] + document[:actions]).to_h { |d| [d[:name], d[:reach]] }

      expect(reaches).to include("open_board" => "published", "shared_list" => "consented",
                                 "staff_book" => "role", "catalog" => "principal")
      # Every descriptor carries one — schema-descriptor.schema.json makes it
      # REQUIRED, so a verb whose reach were merely omitted would leave the
      # served catalog non-conformant rather than quietly defaulting.
      expect(reaches.values).to all(be_a(String))
    end

    it "keeps reach a property of the DECLARATION, not of the class" do
      expect(SpecReachController.kiosk_declarations.transform_values { |d| d[:reach] })
        .to eq("open_board" => :published, "shared_list" => :consented, "staff_book" => :role)
    end

    # ── K-921: one controller, both kinds ────────────────────────────────
    it "registers a query AND an action declared on the SAME controller" do
      expect(Kiosk::Server::Queries.known).to include("board_listings")
      expect(Kiosk::Server::Actions.known).to include("post_to_board")
      expect(SpecBoardController.kiosk_declarations.transform_values { |d| d[:kind] })
        .to eq("board_listings" => :query, "post_to_board" => :action)
    end

    it "re-registers BOTH kinds from one class on every reload" do
      # `kiosk_register!` is what the engine's to_prepare runs on every reload,
      # and it now has to route each declaration to its OWN registry rather
      # than to the one kind the class used to have.
      Kiosk::Server::Queries.reset!
      Kiosk::Server::Actions.reset!
      SpecBoardController.kiosk_register!

      expect(Kiosk::Server::Queries.known).to include("board_listings")
      expect(Kiosk::Server::Actions.known).to include("post_to_board")
    end
  end

  describe "running a query through the executor" do
    it "returns the rendered rows as the rows payload" do
      result = execute(:query, { name: "catalog" })

      expect(result.kind).to eq(:rows)
      expect(result.payload).to eq([{ "sku" => "MILK-1L", "price_cents" => 199 },
                                    { "sku" => "OATS-500G", "price_cents" => 249 }])
    end

    it "hands the agent's params to the action as ordinary params" do
      result = execute(:query, { name: "catalog", q: "oats" })

      expect(result.payload).to eq([{ "sku" => "OATS-500G", "price_cents" => 249 }])
    end

    it "exposes the resolved identity as kiosk_identity" do
      result = execute(:query, { name: "whoami" })

      expect(result.payload["user_id"]).to eq("u-1")
      expect(result.payload["agent_id"]).to eq("a-1")
    end

    it "carries the cursor of a paginated page onto the Result, not into the body" do
      result = execute(:query, { name: "my_orders" })

      expect(result.kind).to eq(:rows)
      expect(result.payload).to eq([{ "order_id" => "o-1", "for" => "u-1" }])
      expect(Kiosk::Server::Cursor.decode_offset(result.next_cursor)).to eq(1)
      # T-092: the body is the bare rows; the cursor leaves as a `Link` header.
      expect(result.to_payload).to eq([{ "order_id" => "o-1", "for" => "u-1" }])
    end

    it "runs inside the wire's GUC-scoped transaction" do
      execute(:query, { name: "catalog" })

      expect(connection.bound(/set_config/).first.last.first).to eq("app.current_user_id")
    end
  end

  describe "running an action through the executor" do
    it "returns the rendered object as the value payload" do
      result = execute(:run, { name: "create_order", items: [{ sku: "MILK-1L" }] })

      expect(result.kind).to eq(:value)
      expect(result.payload).to eq("order_id" => "o-1", "item_count" => 1, "for" => "u-1")
    end

    it "never lets a wire name reach an undeclared method" do
      expect { execute(:run, { name: "place" }) }
        .to raise_error(Kiosk::Server::Errors::NotFound, /Unknown action/)
    end
  end

  describe "errors" do
    it "maps a rendered 400 to bad_request, keeping the handler's message and hint" do
      expect { execute(:run, { name: "create_order" }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.message).to eq("at least one item is required")
          expect(e.hint).to eq("pass items: [{sku:, quantity:}]")
          expect(e.code).to eq("bad_request")
          expect(e.http_status).to eq(400)
        }
    end

    it "maps a rendered 403 to forbidden" do
      expect { execute(:run, { name: "cancel_everything" }) }
        .to raise_error(Kiosk::Server::Errors::Base, /may not cancel/) { |e|
          expect(e.code).to eq("forbidden")
          expect(e.http_status).to eq(403)
        }
    end

    it "lets a handler raise a wire error no HTTP status can carry" do
      expect { execute(:run, { name: "request_kyc" }) }
        .to raise_error(Kiosk::Server::Errors::KycRequired) { |e|
          expect(e.code).to eq("kyc_required")
          expect(e.http_status).to eq(403)
        }
    end

    it "turns an unhandled exception into action_failed, not a silent success" do
      expect { execute(:run, { name: "explode" }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed, /raised RuntimeError: boom/)
    end
  end

  describe "Rails-native raises (the T-054 rescue_from seam)" do
    it "maps params.require's ParameterMissing to bad_request — no Kiosk classes in the handler" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "Requires a param the caller did not send."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def strict
          params.require(:sku)
          render json: { ok: true }
        end
      end
      stub_const("SpecStrictController", klass)

      expect { execute(:run, { name: "strict" }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.code).to eq("bad_request")
          expect(e.http_status).to eq(400)
          expect(e.message).to include("sku")
        }
    end

    it "maps an exception the HOST registered in rescue_responses, Pundit-style" do
      # This is the whole point of reusing Rails' own table: the host app's
      # `config.action_dispatch.rescue_responses` entries (a policy library's
      # NotAuthorizedError → :forbidden, Active Record's RecordNotFound →
      # :not_found) reach the wire with zero Kiosk configuration.
      stub_const("SpecVetoError", Class.new(StandardError))
      ActionDispatch::ExceptionWrapper.rescue_responses["SpecVetoError"] = :forbidden
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "Raises the host's own policy error."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def vetoed = raise(SpecVetoError, "policy said no")
      end
      stub_const("SpecVetoedController", klass)

      expect { execute(:run, { name: "vetoed" }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.code).to eq("forbidden")
          expect(e.http_status).to eq(403)
          expect(e.message).to eq("policy said no")
        }
    ensure
      ActionDispatch::ExceptionWrapper.rescue_responses.delete("SpecVetoError")
    end

    it "lets the operator's own rescue_from win over the mixin's floor" do
      stub_const("SpecTeapotError", Class.new(StandardError))
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        rescue_from(SpecTeapotError) do
          render json: { error: "handled by the operator" }, status: :conflict
        end
        kind :action
        description "Raises an error the operator's own rescue_from handles."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def brew = raise(SpecTeapotError)
      end
      stub_const("SpecTeapotController", klass)

      expect { execute(:run, { name: "brew" }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.code).to eq("conflict")
          expect(e.message).to eq("handled by the operator")
        }
    end
  end

  describe "rendering an explicit wire code" do
    it "carries a 403 code a bare status cannot name (rls_denied)" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :query
        description "Answers with the RLS denial code, Rails-natively."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def blocked
          render json: { ok: false, error: { code: "rls_denied", message: "row policy said no" } },
                 status: :forbidden
        end
      end
      stub_const("SpecBlockedController", klass)

      expect { execute(:query, { name: "blocked" }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.code).to eq("rls_denied")
          expect(e.http_status).to eq(403)
          expect(e.message).to eq("row policy said no")
        }
    end

    it "carries a SPECIFIC 402 — named by the handler, never guessed by the seam" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "Needs a card on file before it can run."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def needs_card
          render json: { ok: false, error: { code: "payment_setup_required", message: "no card on file" } },
                 status: :payment_required
        end
      end
      stub_const("SpecNeedsCardController", klass)

      expect { execute(:run, { name: "needs_card" }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.code).to eq("payment_setup_required")
          expect(e.http_status).to eq(402)
        }
    end
  end

  describe "the end-to-end wire path" do
    let(:token) do
      Kiosk::Server::JwtIssuer.issue(
        claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
        audience: "https://provider.example",
      )
    end

    before do
      Kiosk.configure do |c|
        c.issuer      = "https://provider.example"
        c.roles       = %i[customer]
        c.signing_key = Kiosk::Server::SigningKey.generate
      end
      [SpecCatalogController, SpecOrdersController, SpecBoardController].each(&:kiosk_register!)
      allow(::ActiveRecord::Base).to receive(:connection).and_return(connection)
      allow(::ActiveRecord::Base).to receive(:lease_connection).and_return(connection)
    end

    # The 0.4 wire, exercised the way a router reaches it: the verb NAME is a
    # path segment (`params[:kiosk_verb]`), a query is a GET whose arguments
    # are the query string and an action is a POST whose arguments are the
    # body. There is no `name` field and no /query or /run endpoint to post to.
    def get_wire(name, args = {}, **opts)
      query = args.empty? ? "" : "?#{URI.encode_www_form(args)}"
      env = Rack::MockRequest.env_for(
        "https://provider.example/kiosk/#{name}#{query}",
        method: "GET",
        "HTTP_AUTHORIZATION" => "Bearer #{token}", **opts
      )
      dispatch(:show, name, env)
    end

    def post_wire(name, payload = {}, **opts)
      env = Rack::MockRequest.env_for(
        "https://provider.example/kiosk/#{name}",
        method: "POST", input: JSON.generate(payload),
        "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token}", **opts
      )
      dispatch(:create, name, env)
    end

    def dispatch(action, name, env)
      env["action_dispatch.request.path_parameters"] =
        { controller: "kiosk/server/verb", action: action.to_s, kiosk_verb: name.to_s }
      status, headers, body = Kiosk::Server::VerbController.action(action).call(env)
      raw = +""
      body.each { |chunk| raw << chunk }
      [status, JSON.parse(raw), headers]
    end

    it "answers a query with the rendered rows, verbatim" do
      status, payload = get_wire("catalog", { q: "milk" })

      expect(status).to eq(200)
      expect(payload).to eq([{ "sku" => "MILK-1L", "price_cents" => 199 }])
    end

    it "answers an action with its own object, verbatim" do
      status, payload = post_wire("create_order", { items: [{ sku: "MILK-1L" }] })

      expect(status).to eq(200)
      expect(payload).to eq("order_id" => "o-1", "item_count" => 1, "for" => "u-1")
    end

    # ── K-921, over the wire ─────────────────────────────────────────────
    #
    # The proof that the split is REMOVED rather than merely unenforced: both
    # verbs below are declared in ONE class, and each answers on its own HTTP
    # method through the same VerbController a router reaches.
    it "serves a query and an action declared on the SAME controller" do
      status, rows = get_wire("board_listings")
      expect(status).to eq(200)
      expect(rows).to eq([{ "listing_id" => "l-1", "for" => "u-1" }])

      status, payload = post_wire("post_to_board", { title: "Carbon road bike" })
      expect(status).to eq(200)
      expect(payload).to eq("listing_id" => "l-2", "title" => "Carbon road bike")
    end

    it "still refuses the wrong method for each of the two, from one class" do
      status, problem, headers = post_wire("board_listings", {})
      expect(status).to eq(405)
      expect(problem["code"]).to eq("method_not_allowed")
      expect(headers["Allow"]).to eq("GET")

      status, problem, headers = get_wire("post_to_board")
      expect(status).to eq(405)
      expect(problem["code"]).to eq("method_not_allowed")
      expect(headers["Allow"]).to eq("POST")
    end

    it "renders a handler's refusal as a problem document" do
      # `items: []` satisfies the declared input_schema (an array, present) and
      # is refused by the HANDLER's own emptiness guard — so this exercises the
      # handler's refusal reaching the wire, not the schema layer's.
      status, problem, headers = post_wire("create_order", { items: [] })

      expect(status).to eq(400)
      expect(headers["Content-Type"]).to start_with("application/problem+json")
      expect(problem["code"]).to eq("bad_request")
      expect(problem["type"]).to eq("https://kiosk.tech/problems/bad_request")
      expect(problem["detail"]).to eq("at least one item is required")
      expect(problem["hint"]).to eq("pass items: [{sku:, quantity:}]")
    end

    it "gives a RENDERED payment_setup_required the same WWW-Authenticate as a raised one" do
      # The challenge header is keyed on the wire CODE (T-054), so the
      # Rails-native way of saying a specific 402 loses nothing.
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "Needs a card on file before it can run."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def needs_card
          render json: { ok: false, error: { code: "payment_setup_required", message: "no card on file" } },
                 status: :payment_required
        end
      end
      stub_const("SpecNeedsCardController", klass)

      status, problem, headers = post_wire("needs_card")

      expect(status).to eq(402)
      expect(problem["code"]).to eq("payment_setup_required")
      expect(headers["WWW-Authenticate"]).to eq(%(Payment realm="https://provider.example", method="ap2"))
    end

    it "emits NO WWW-Authenticate on payment_failed — the third 402, which no scheme names" do
      # Spec §9 (matrix SPEC-099), a MUST-NOT and the one branch of the 402
      # trio that is right BY CONSTRUCTION: `www_authenticate_for` is a
      # two-`when` `case` with no `else`, so a stray third branch would put a
      # challenge on a refusal that has nothing to challenge — an assistant
      # told to re-authenticate against a card that was simply declined.
      #
      # THE POSITIVE CONTROL IS THE TEST ABOVE, on purpose and in this same
      # file: the identical render path, one code apart, DOES get its header.
      # Without that pairing an assertion of absence would also pass if the
      # header were never emitted anywhere. The third member of the trio
      # (`pow_required`) is controlled in wire_controller_402_spec.rb:74.
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "The card was declined."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def declined
          render json: { ok: false, error: { code: "payment_failed", message: "card declined" } },
                 status: :payment_required
        end
      end
      stub_const("SpecDeclinedController", klass)

      status, problem, headers = post_wire("declined")

      expect(status).to eq(402)
      expect(problem["code"]).to eq("payment_failed")
      expect(headers).not_to have_key("WWW-Authenticate")
    end

    it "survives the host app's forgery protection" do
      # Every real Rails app installs protect_from_forgery on ActionController::Base;
      # the sub-dispatch cannot carry a token, so the mixin skips it on include.
      # Without that, this POST would be an InvalidAuthenticityToken → 500.
      callbacks = SpecOrdersController._process_action_callbacks.map(&:filter)
      expect(callbacks).not_to include(:verify_authenticity_token)
      expect(ApplicationController._process_action_callbacks.map(&:filter))
        .to include(:verify_authenticity_token)

      expect(post_wire("create_order", { items: [1] }).first).to eq(200)
    end

    it "seeds the handler's request with the caller's headers" do
      _status, payload = get_wire("whoami", {}, "HTTP_USER_AGENT" => "kiosk-cli/1.0")

      expect(payload["user_agent"]).to eq("kiosk-cli/1.0")
      expect(payload["wire_name"]).to eq("whoami")
    end
  end

  describe "guards" do
    it "404s a request that did not come through the Kiosk wire, as a problem document" do
      # THE BODY IS CLIENT-FACING (K-1092). The guard returns early under
      # sub-dispatch, so what it renders is never re-wrapped by the Executor: it
      # goes straight to whoever dialed a route an operator drew at a handler
      # controller. It used to answer the 0.3 `{ok:false, error:{…}}` envelope —
      # deleted with the endpoints that served it (K-808, T-074 = A) — which made
      # it the last shipped body emitting that shape to a client. Contrast
      # `kiosk_rescue_to_wire`, which keeps the nested shape ON PURPOSE: that one
      # is the internal sub-dispatch protocol between a handler and
      # HandlerDispatch, and the Executor re-wraps it before anything sees it.
      env = Rack::MockRequest.env_for("https://provider.example/catalog", method: "POST")
      status, headers, body = SpecCatalogController.action(:catalog).call(env)
      raw = +""
      body.each { |chunk| raw << chunk }
      problem      = JSON.parse(raw)
      content_type = headers.find { |k, _| k.to_s.downcase == "content-type" }&.last

      expect(status).to eq(404)
      expect(content_type).to start_with(Kiosk::Server::Errors::PROBLEM_CONTENT_TYPE)
      expect(problem).to include(
        "type"   => "https://kiosk.tech/problems/not_found",
        "title"  => "Not found",
        "status" => 404,
        "code"   => "not_found",
      )
      expect(problem["detail"]).to match(/Kiosk wire only/)
      expect(problem["hint"]).to match(%r{<query-name>})
      # FLAT: neither of the two members the retired envelope owned survives.
      expect(problem.keys).not_to include("ok")
      expect(problem.keys).not_to include("error")
    end

    it "refuses to be included into something that is not a controller" do
      expect { Class.new { include Kiosk::Handler } }
        .to raise_error(ArgumentError, /needs an ActionController subclass/)
    end

    it "refuses a declaration with no kind" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Handler
          description "Says nothing about which verb reaches it."
          input_schema type: "object"
          output_schema true
          def browse = render(json: [])
        end
      }.to raise_error(ArgumentError, /without a `kind`/)
    end

    it "refuses a kind that is neither :query nor :action" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Handler
          kind :mutation
        end
      }.to raise_error(ArgumentError, /not a Kiosk verb kind/)
    end

    it "refuses a reach outside the four the spec names" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Handler
          reach :public
        end
      }.to raise_error(ArgumentError, /not a Kiosk verb reach/)
    end

    # The SAME-CLASS half of one-name-one-kind. It could not arise before
    # K-921 — a class had one kind — and it is refused where the operator has
    # both methods in hand. The cross-class half is HandlerRegistrations'.
    it "refuses one name declared as both kinds on the same class" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Handler
          kind :query
          description "The read."
          input_schema type: "object"
          output_schema true
          def board = render(json: [])

          kind :action
          description "The write, under the same name."
          input_schema type: "object"
          output_schema true
          wire_name "board"
          def board_write = render(json: {})
        end
      }.to raise_error(ArgumentError, /already declares it as a query/)
    end

    # ── spec §8.1/§8.3 + T-073 = A, refused where the mistake is made ────
    #
    # All four raise at CLASS-BODY LOAD, so an operator meets them at boot with
    # the class and the method in hand — not as a verb that turns out to be
    # unreachable, or a descriptor an assistant finds incomplete.

    it "refuses a verb name that is not one legal path segment" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Handler
          kind :query
          description "Shouty."
          input_schema type: "object"
          output_schema true
          wire_name "Browse-Listings"
          def browse = render(json: [])
        end
      }.to raise_error(ArgumentError, /not a legal verb name/)
    end

    it "refuses a verb name the engine draws itself" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Handler
          kind :query
          description "Would be shadowed by the wire's own route."
          input_schema type: "object"
          output_schema true
          def schema = render(json: [])
        end
      }.to raise_error(ArgumentError, /RESERVED/)
    end

    it "refuses a declaration with no input_schema" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Handler
          kind :query
          description "Publishes no input contract."
          output_schema true
          def browse = render(json: [])
        end
      }.to raise_error(ArgumentError, /without input_schema/)
    end

    it "refuses a declaration with no output_schema" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Handler
          kind :query
          description "Publishes no result contract."
          input_schema type: "object"
          def browse = render(json: [])
        end
      }.to raise_error(ArgumentError, /without output_schema/)
    end

    # The reserved list is the engine's own route table, and it must stay that
    # way: `bin/check-kiosk-names` holds the two against each other, and this
    # pins the names the mixin refuses today so a silent shrink is visible.
    it "reserves every first path segment the engine draws under the mount" do
      expect(Kiosk::Server::HandlerMixin::RESERVED_NAMES)
        .to contain_exactly("agents", "auth", "oauth", "pay", "schema")
    end

    it "404s a verb whose method stopped being a public action" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :query
        description "Goes private."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def vanishing = render(json: [])
      end
      klass.send(:private, :vanishing)

      expect { execute(:query, { name: "vanishing" }) }
        .to raise_error(Kiosk::Server::Errors::NotFound, /no longer dispatchable/)
    end
  end
end
