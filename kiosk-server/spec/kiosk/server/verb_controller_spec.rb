# frozen_string_literal: true

# THE 0.4 PER-VERB WIRE at the wire level (T-068 slice 1).
#
# `GET <endpoint>/<query-name>` and `POST <endpoint>/<action-name>`, resolved
# against the same registry `GET <endpoint>/schema` renders its descriptors
# from. The argument ENCODING is unit-tested next door in
# `argument_decoder_spec.rb`; what is proved here is that a real request
# reaches it, that a refusal comes back as the wire's own 400, and that the
# 0.3 wire is untouched — because 0.4's hard cut (T-074 = A) is the CUTOVER
# slice, and cutting `POST /kiosk/{query,run}` here would have broken the
# eight demos mid-build.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host, so `path_parameters` is set by hand exactly as the
# router would.

require "rack/mock"
require "json"

RSpec.describe Kiosk::Server::VerbController do
  let(:connection) { FakeConnection.new }

  before do
    Kiosk.configure do |c|
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.issuer      = "https://demo.example"
      c.roles       = %i[customer]
      c.agent_idp   = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
    end
    # No database in the gem's own env; SessionContext only needs a connection
    # that answers #transaction and #exec_query.
    allow_any_instance_of(described_class).to receive(:connection_for).and_return(connection)
    allow_any_instance_of(Kiosk::Server::WireController)
      .to receive(:connection_for).and_return(connection)
  end

  def token
    Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
      audience: "https://demo.example",
    )
  end

  # One per-verb request. `action` is :show for a GET, :create for a POST;
  # `kiosk_verb` is the path segment the router would have captured.
  def call_verb(method, name, query: nil, body: nil, auth: true)
    path   = "/kiosk/#{name}#{query ? "?#{query}" : ""}"
    action = method == :get ? :show : :create
    opts   = { method: method.to_s.upcase }
    if body
      opts[:input] = body
      opts["CONTENT_TYPE"] = "application/json"
    end
    opts["HTTP_AUTHORIZATION"] = "Bearer #{token}" if auth

    env = Rack::MockRequest.env_for(path, **opts)
    env["action_dispatch.request.path_parameters"] =
      { controller: "kiosk/server/verb", action: action.to_s, kiosk_verb: name }

    dispatch(described_class, action, env)
  end

  # The 0.3 wire, for the "still working" half.
  def call_wire(action, body)
    env = Rack::MockRequest.env_for(
      "/kiosk/#{action}", method: "POST", input: body,
      "CONTENT_TYPE" => "application/json",
      "HTTP_AUTHORIZATION" => "Bearer #{token}"
    )
    dispatch(Kiosk::Server::WireController, action, env)
  end

  def dispatch(controller, action, env)
    status, _headers, body = controller.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  # A query whose handler reports back what it was actually handed, so an
  # assertion about coercion is an assertion about what the HANDLER sees —
  # not about what the decoder returned.
  def declare_echo(input_schema)
    declare_query("echo", input_schema: input_schema) do
      render json: [{
        min_stars: params[:min_stars],
        klass:     params[:min_stars].class.name,
        amenity:   params[:amenity],
        seen:      params.to_unsafe_h.keys.sort,
      }]
    end
  end

  describe "a query is a GET at its own path" do
    before { declare_query("salons") { render json: [{ id: 1, name: "Combette on Park" }] } }

    it "serves it and answers with the wire envelope" do
      status, body = call_verb(:get, "salons")
      expect(status).to eq(200)
      expect(body[:ok]).to be(true)
      expect(body[:kind]).to eq("rows")
      expect(body[:rows]).to eq([{ id: 1, name: "Combette on Park" }])
    end

    it "answers 401 before it will say whether the verb exists" do
      # Design §3.5 lists the declared-verb check BEFORE authentication;
      # serving it that way would enumerate the catalog to an unauthenticated
      # probe (404 for a name that does not exist, 401 for one that does) on a
      # surface that is Bearer-gated today. Both answer 401 here.
      expect(call_verb(:get, "salons",     auth: false).first).to eq(401)
      expect(call_verb(:get, "frobnicate", auth: false).first).to eq(401)
    end

    it "answers an unknown name 404, naming what IS registered" do
      status, body = call_verb(:get, "frobnicate")
      expect(status).to eq(404)
      expect(body.dig(:error, :code)).to eq("not_found")
      expect(body.dig(:error, :hint)).to include("salons")
    end
  end

  describe "an action is a POST at its own path" do
    before do
      declare_action("book_appointment") do
        render json: { appointment_id: 7, salon_id: params[:salon_id] }
      end
    end

    it "serves it with a JSON body" do
      status, body = call_verb(:post, "book_appointment", body: JSON.generate(salon_id: 3))
      expect(status).to eq(200)
      expect(body[:kind]).to eq("value")
      expect(body[:value]).to eq(appointment_id: 7, salon_id: 3)
    end
  end

  describe "the HTTP method carries the read/write semantics" do
    before do
      declare_query("salons") { render json: [] }
      declare_action("book_appointment") { render json: {} }
    end

    it "answers a GET at an ACTION's name with the method it wanted" do
      status, body = call_verb(:get, "book_appointment")
      expect(status).to eq(404)
      expect(body.dig(:error, :message)).to include("is an action, not a query")
      expect(body.dig(:error, :hint)).to include("POST /kiosk/book_appointment")
    end

    it "answers a POST at a QUERY's name with the method it wanted" do
      status, body = call_verb(:post, "salons", body: "{}")
      expect(status).to eq(404)
      expect(body.dig(:error, :message)).to include("is a query, not an action")
      expect(body.dig(:error, :hint)).to include("GET /kiosk/salons")
    end
  end

  describe "arguments reach the handler with their declared types" do
    before do
      declare_echo(type: "object", additionalProperties: false,
                   properties: { min_stars: { type: "integer" },
                                 amenity:   { type: "array", items: { type: "string" } } })
    end

    it "hands the handler an Integer, not the query string's String" do
      _status, body = call_verb(:get, "echo", query: "min_stars=4")
      expect(body[:rows].first[:min_stars]).to eq(4)
      expect(body[:rows].first[:klass]).to eq("Integer")
    end

    it "decodes the percent-encoded and the raw bracket spellings identically" do
      _s1, percent = call_verb(:get, "echo", query: "amenity%5B%5D=pool&amenity%5B%5D=spa")
      _s2, raw     = call_verb(:get, "echo", query: "amenity[]=pool&amenity[]=spa")
      expect(percent[:rows].first[:amenity]).to eq(%w[pool spa])
      expect(raw[:rows]).to eq(percent[:rows])
    end

    it "refuses a value that will not coerce with a 400 naming the parameter" do
      status, body = call_verb(:get, "echo", query: "min_stars=four")
      expect(status).to eq(400)
      expect(body.dig(:error, :code)).to eq("bad_request")
      expect(body.dig(:error, :message)).to include("min_stars")
    end

    it "refuses a shape a query cannot carry with a 400 that names the ACTION remedy" do
      status, body = call_verb(:get, "echo", query: "price%5Brange%5D%5Bmin%5D=1")
      expect(status).to eq(400)
      expect(body.dig(:error, :message)).to include("price")
      expect(body.dig(:error, :hint)).to include("ACTION")
    end

    it "does not read a query string on a POST — an action's arguments are its body" do
      declare_action("noop") { render json: { seen: params.to_unsafe_h.keys.sort } }
      _status, body = call_verb(:post, "noop", query: "sneaky=1", body: "{}")
      expect(body[:value][:seen]).not_to include("sneaky")
    end
  end

  describe "input_schema is executable when validate_requests is on" do
    before { Kiosk.configuration.validate_requests = true }

    it "accepts limit and cursor on a verb that declares neither, with a CLOSED schema" do
      # T-070 rule (7). getgrocery's `catalog` is exactly this schema, and
      # without the reserved rule the `?limit=` the pagination contract
      # invites would 400 as a disallowed additional property.
      declare_query("catalog", input_schema: { type: "object", additionalProperties: false,
                                               properties: {}, required: [] }) do
        render json: []
      end
      expect(call_verb(:get, "catalog", query: "limit=20&cursor=eyJvIjoyMH0").first).to eq(200)
    end

    it "refuses a value outside a declared enum — K-717's schema half" do
      declare_query("availability", input_schema: {
                      type: "object", additionalProperties: false,
                      properties: { time: { type: "string", enum: %w[18:00 20:00] } },
                    }) { render json: [] }

      status, body = call_verb(:get, "availability", query: "time=19:00")
      expect(status).to eq(400)
      expect(body.dig(:error, :code)).to eq("bad_request")
      expect(body.dig(:error, :message)).to include("time")
    end

    it "still refuses an undeclared parameter under additionalProperties: false" do
      declare_query("catalog", input_schema: { type: "object", additionalProperties: false,
                                               properties: {}, required: [] }) { render json: [] }
      status, body = call_verb(:get, "catalog", query: "nope=1")
      expect(status).to eq(400)
      expect(body.dig(:error, :message)).to include("nope")
    end
  end

  describe "the 0.3 wire is untouched — the hard cut is the CUTOVER slice" do
    before { declare_query("salons") { render json: [{ id: 1 }] } }

    it "still serves POST <endpoint>/query by name" do
      status, body = call_wire(:query, JSON.generate(name: "salons"))
      expect(status).to eq(200)
      expect(body[:rows]).to eq([{ id: 1 }])
    end

    it "answers both wires with byte-identical bodies for the same call" do
      _old_status, old_body = call_wire(:query, JSON.generate(name: "salons"))
      _new_status, new_body = call_verb(:get, "salons")
      expect(new_body).to eq(old_body)
    end

    it "computes the SAME PoW fingerprint on both wires, so a proof is spendable on either" do
      seen = []
      allow(Kiosk::Server::PowGate).to receive(:gate) { |**kwargs| seen << kwargs.slice(:command, :body) }

      call_wire(:query, JSON.generate(name: "salons"))
      call_verb(:get, "salons")

      expect(seen.length).to eq(2)
      expect(seen[1]).to eq(seen[0])
      expect(seen[0]).to eq(command: :query, body: { name: "salons" })
    end
  end
end
