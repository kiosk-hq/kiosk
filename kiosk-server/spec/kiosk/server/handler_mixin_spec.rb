# frozen_string_literal: true

# `include Kiosk::Query` / `include Kiosk::Action` — the operator-facing seam
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
require "json"

# An operator's OWN base class — the shape K-495 describes and T-056 will
# scaffold. Kiosk imposes neither this class nor its superclass; it only
# supplies the module included here.
class SpecKioskQueriesController < ApplicationController
  include Kiosk::Query
end

class SpecCatalogController < SpecKioskQueriesController
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

  description "Lists the caller's own orders, one page at a time."
  def my_orders
    render_kiosk_page([{ "order_id" => "o-1", "for" => kiosk_identity&.user_id }],
                      next_cursor: Kiosk::Server::Cursor.encode_offset(1))
  end

  description "Reports who the wire says is calling."
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
  include Kiosk::Action

  description "Places an order for the assistant's human. Nothing is charged " \
              "until the cart is settled with `pay`."
  input_schema type: "object", properties: { items: { type: "array" } }, required: %w[items]
  # The Ruby method is `place`; agents call it `create_order`.
  wire_name "create_order"
  def place
    items = params[:items]
    if items.blank?
      return render json: { error: "at least one item is required",
                            hint: "pass items: [{sku:, quantity:}]" }, status: :bad_request
    end

    render json: { order_id: "o-1", item_count: items.size, for: kiosk_identity&.user_id }
  end

  description "Refuses, to show a policy refusal reaching the wire as forbidden."
  def cancel_everything
    render json: { error: "assistants may not cancel every order at once" }, status: :forbidden
  end

  description "Raises the wire error whose code no HTTP status can carry."
  def request_kyc
    raise Kiosk::Server::Errors::KycRequired, "attestation missing: over_18"
  end

  description "Blows up, to show an unhandled exception is not a silent 200."
  def explode
    raise "boom"
  end
end

RSpec.describe "Kiosk::Query / Kiosk::Action (the operator mixin)" do
  let(:identity) { build_identity(user_id: "u-1", agent_id: "a-1") }
  let(:connection) { FakeConnection.new }

  # The class bodies above registered as they were read; spec_helper resets the
  # registries before every example, so put them back.
  before do
    [SpecCatalogController, SpecOrdersController].each(&:kiosk_register!)
  end

  # The REAL dispatch path, minus HTTP: exactly what WireController calls.
  def execute(kind, args)
    Kiosk::Server::CurrentRequest.with(identity: identity) do
      Kiosk::Server::Executor.call(kind: kind, args: args, identity: identity, connection: connection)
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

    it "reaches the wire catalog through the schema verb" do
      result = execute(:schema, {})

      names = result.payload[:queries].map { |d| d[:name] }
      expect(names).to include("catalog")
      expect(result.payload[:actions].map { |d| d[:name] }).to include("create_order")
    end

    it "inherits the kind from the operator's own base class" do
      expect(SpecCatalogController.kiosk_kind).to eq(:query)
      expect(SpecKioskQueriesController.kiosk_kind).to eq(:query)
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

    it "carries the cursor of a paginated page into the envelope" do
      result = execute(:query, { name: "my_orders" })

      expect(result.kind).to eq(:rows)
      expect(result.payload).to eq([{ "order_id" => "o-1", "for" => "u-1" }])
      expect(Kiosk::Server::Cursor.decode_offset(result.next_cursor)).to eq(1)
      expect(result.to_envelope[:next]).to eq(result.next_cursor)
    end

    it "runs inside the wire's GUC-scoped transaction" do
      execute(:query, { name: "catalog" })

      expect(connection.executed_sql.first).to start_with(%(SET LOCAL "app"."current_user_id"))
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
        include Kiosk::Action
        description "Requires a param the caller did not send."
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
        include Kiosk::Action
        description "Raises the host's own policy error."
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
        include Kiosk::Action
        rescue_from(SpecTeapotError) do
          render json: { error: "handled by the operator" }, status: :conflict
        end
        description "Raises an error the operator's own rescue_from handles."
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
        include Kiosk::Query
        description "Answers with the RLS denial code, Rails-natively."
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
        include Kiosk::Action
        description "Needs a card on file before it can run."
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
      [SpecCatalogController, SpecOrdersController].each(&:kiosk_register!)
      allow(::ActiveRecord::Base).to receive(:connection).and_return(connection)
    end

    def post_wire(verb, payload, **opts)
      env = Rack::MockRequest.env_for(
        "https://provider.example/kiosk/#{verb}",
        method: "POST", input: JSON.generate(payload),
        "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token}", **opts
      )
      status, headers, body = Kiosk::Server::WireController.action(verb).call(env)
      raw = +""
      body.each { |chunk| raw << chunk }
      [status, JSON.parse(raw), headers]
    end

    it "answers a query with the ordinary success envelope" do
      status, envelope = post_wire(:query, { name: "catalog", q: "milk" })

      expect(status).to eq(200)
      expect(envelope).to eq("ok" => true, "kind" => "rows",
                             "rows" => [{ "sku" => "MILK-1L", "price_cents" => 199 }])
    end

    it "answers an action with the ordinary success envelope" do
      status, envelope = post_wire(:run, { name: "create_order", items: [{ sku: "MILK-1L" }] })

      expect(status).to eq(200)
      expect(envelope["kind"]).to eq("value")
      expect(envelope["value"]).to eq("order_id" => "o-1", "item_count" => 1, "for" => "u-1")
    end

    it "renders a handler's refusal as the ordinary error envelope" do
      status, envelope = post_wire(:run, { name: "create_order" })

      expect(status).to eq(400)
      expect(envelope["error"]).to eq("code" => "bad_request",
                                      "message" => "at least one item is required",
                                      "hint" => "pass items: [{sku:, quantity:}]")
    end

    it "gives a RENDERED payment_setup_required the same WWW-Authenticate as a raised one" do
      # The challenge header is keyed on the wire CODE (T-054), so the
      # Rails-native way of saying a specific 402 loses nothing.
      klass = Class.new(ApplicationController) do
        include Kiosk::Action
        description "Needs a card on file before it can run."
        def needs_card
          render json: { ok: false, error: { code: "payment_setup_required", message: "no card on file" } },
                 status: :payment_required
        end
      end
      stub_const("SpecNeedsCardController", klass)

      status, envelope, headers = post_wire(:run, { name: "needs_card" })

      expect(status).to eq(402)
      expect(envelope["error"]["code"]).to eq("payment_setup_required")
      expect(headers["WWW-Authenticate"]).to eq(%(Payment realm="https://provider.example", method="ap2"))
    end

    it "survives the host app's forgery protection" do
      # Every real Rails app installs protect_from_forgery on ActionController::Base;
      # the sub-dispatch cannot carry a token, so the mixin skips it on include.
      # Without that, this POST would be an InvalidAuthenticityToken → 500.
      callbacks = SpecOrdersController._process_action_callbacks.map(&:filter)
      expect(callbacks).not_to include(:verify_authenticity_token)
      expect(ApplicationController._process_action_callbacks.map(&:filter))
        .to include(:verify_authenticity_token)

      expect(post_wire(:run, { name: "create_order", items: [1] }).first).to eq(200)
    end

    it "seeds the handler's request with the caller's headers" do
      _status, envelope = post_wire(:query, { name: "whoami" }, "HTTP_USER_AGENT" => "kiosk-cli/1.0")

      expect(envelope["rows"]["user_agent"]).to eq("kiosk-cli/1.0")
      expect(envelope["rows"]["wire_name"]).to eq("whoami")
    end
  end

  describe "guards" do
    it "404s a request that did not come through the Kiosk wire" do
      env = Rack::MockRequest.env_for("https://provider.example/catalog", method: "POST")
      status, _headers, body = SpecCatalogController.action(:catalog).call(env)
      raw = +""
      body.each { |chunk| raw << chunk }

      expect(status).to eq(404)
      expect(JSON.parse(raw).dig("error", "message")).to match(/Kiosk wire only/)
    end

    it "refuses to be included into something that is not a controller" do
      expect { Class.new { include Kiosk::Query } }
        .to raise_error(ArgumentError, /needs an ActionController subclass/)
    end

    it "refuses a controller that would be both a query and an action" do
      expect {
        Class.new(ApplicationController) do
          include Kiosk::Query
          include Kiosk::Action
        end
      }.to raise_error(ArgumentError, /queries OR actions, never both/)
    end

    it "404s a verb whose method stopped being a public action" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Query
        description "Goes private."
        def vanishing = render(json: [])
      end
      klass.send(:private, :vanishing)

      expect { execute(:query, { name: "vanishing" }) }
        .to raise_error(Kiosk::Server::Errors::NotFound, /no longer dispatchable/)
    end
  end
end
