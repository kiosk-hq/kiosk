# frozen_string_literal: true

# Wire-level controller specs.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host.

require "rack/mock"
require "json"

RSpec.describe "wire-surface controller auth" do
  def dispatch(controller, action, env)
    status, headers, body = controller.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    @last_headers = headers
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  def last_headers = @last_headers

  def bearer_env(path, token, **opts)
    Rack::MockRequest.env_for(path, "HTTP_AUTHORIZATION" => "Bearer #{token}", **opts)
  end

  # EVERY refusal on the wire and the auth plane is an RFC 9457 problem
  # document since the 0.4 cutover: `application/problem+json` (the media type
  # is half of what makes it one), a per-code `type` URI and `title`, the
  # status restated in the body, and the SAME closed-vocabulary token — moved
  # from `error.code` to the TOP-LEVEL `code`, with the old `message` as
  # `detail`. The one deliberate exception is `/oauth/*`, which keeps RFC
  # 8628's own error object; that block below asserts it unchanged.
  def expect_problem(status, body, http:, code:, detail: nil)
    expect(status).to eq(http)
    expect(last_headers["Content-Type"]).to include("application/problem+json")
    expect(body[:type]).to   eq("https://kiosk.tech/problems/#{code}")
    expect(body[:title]).to  eq(Kiosk::Server::Errors::TITLES.fetch(code))
    expect(body[:status]).to eq(http)
    expect(body[:code]).to   eq(code)
    expect(body[:detail]).to include(detail) if detail
  end

  # ─── bad tokens on a wire endpoint are 401, never 500 ────────────
  describe "WireController with the bare DefaultAgentIdp" do
    before do
      Kiosk.configure do |c|
        c.signing_key = Kiosk::Server::SigningKey.generate
        c.issuer      = "https://demo.example"
        c.roles       = %i[customer]
        c.agent_idp   = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
      end
    end

    def schema_status_for(token)
      status, body = dispatch(Kiosk::Server::WireController, :schema,
                              bearer_env("/kiosk/schema", token))
      [status, body]
    end

    it "returns 401 Unauthenticated (not 500) for an EXPIRED token" do
      token = Kiosk::Server::JwtIssuer.issue(
        claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
        audience: "https://demo.example",
        now:      Time.now - 7200,
      )
      status, body = schema_status_for(token)
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    it "returns 401 Unauthenticated (not 500) for a GARBAGE token" do
      status, body = schema_status_for("garbage-not-a-jwt")
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    it "returns 401 Unauthenticated (not 500) for a REVOKED token" do
      token = Kiosk::Server::JwtIssuer.issue(
        claims:   { sub: "u-1", agent_id: "a-rev", role: "customer", actor: "agent" },
        audience: "https://demo.example",
        now:      Time.now - 10,
      )
      Kiosk.configuration.revocation_store.revoke_all("a-rev", at: Time.now.to_i)
      status, body = schema_status_for(token)
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    it "returns 401 Unauthenticated (not 500) for a WRONGLY-SIGNED token" do
      other = Kiosk::Server::SigningKey.generate
      token = Kiosk::Server::JwtIssuer.issue(
        claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
        audience: "https://demo.example", signing_key: other,
      )
      status, body = schema_status_for(token)
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    def wire_token
      Kiosk::Server::JwtIssuer.issue(
        claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
        audience: "https://demo.example",
      )
    end

    # parse_body! raises Errors::BadRequest on a malformed body; it must render
    # a 400 problem document, not escape the action's rescue as an uncaught 500.
    #
    # `POST /kiosk/query`, the 0.3 endpoint this pair dialed, was DELETED at
    # the cutover (T-074 = A). Its successor is the per-verb wire — `POST
    # <endpoint>/<action-name>`, the verb as a PATH SEGMENT — and the verb has
    # to be REGISTERED for a request to reach the body at all, because name
    # resolution runs before the arguments are read.
    def post_verb(name, raw_body)
      env = bearer_env("/kiosk/#{name}", wire_token, method: "POST",
                       input: raw_body, "CONTENT_TYPE" => "application/json")
      env["action_dispatch.request.path_parameters"] =
        { controller: "kiosk/server/verb", action: "create", kiosk_verb: name }
      dispatch(Kiosk::Server::VerbController, :create, env)
    end

    # The other surviving body-reading POST, and the SAME
    # WireController#parse_body! the deleted `query` action ran — literally the
    # same seam in the same class.
    def post_pay(raw_body)
      dispatch(Kiosk::Server::WireController, :pay,
               bearer_env("/kiosk/pay", wire_token, method: "POST",
                          input: raw_body, "CONTENT_TYPE" => "application/json"))
    end

    # Dialed at `pay` rather than at a verb path, deliberately: a per-verb call
    # reads its name off `params[:kiosk_verb]`, and touching `params` makes
    # Rails parse the body FIRST — so syntactically invalid JSON there is
    # ActionDispatch::Http::Parameters::ParseError out of the parameter layer
    # (which a Rails host maps to 400 via rescue_responses) and never reaches
    # Kiosk's own guard. `pay` runs that guard, so this proves it where it runs.
    it "returns 400 bad_request (not 500) for INVALID JSON on a wire POST" do
      status, body = post_pay("{not valid json")
      expect_problem(status, body, http: 400, code: "bad_request", detail: "invalid JSON")
    end

    it "returns 400 bad_request (not 500) for a non-object JSON body on a wire POST" do
      declare_action("place_order") { render json: {} }
      status, body = post_verb("place_order", "[1, 2, 3]")
      expect_problem(status, body, http: 400, code: "bad_request",
                     detail: "must be a JSON object")
    end
  end

  # ─── KYC endpoint uses the CONFIGURED IdP, not a hardcoded one ───
  describe "KycAttestationController IdP resolution" do
    let(:kyc_key)    { OpenSSL::PKey::RSA.generate(2048) }
    let(:kyc_issuer) { "https://kyc.example" }
    let(:identity)   { build_identity(user_id: "u-kyc", agent_id: "a-custom") }
    let(:custom_idp) do
      # A custom adapter that resolves ANY request to a fixed identity —
      # something the bundled DefaultAgentIdp would never do for the garbage
      # bearer below. Success therefore proves the configured idp was used.
      fixed = identity
      Class.new do
        define_method(:verify) { |_request| fixed }
      end.new
    end
    # `[sql, binds]` per statement, not SQL alone: since K-782 the attestation
    # UPDATE carries its agent id and its jsonb payload as `$1`/`$2`, so the id
    # this surface writes to is only visible in the binds.
    let(:executed_sql) { [] }

    before do
      log = executed_sql
      fake_conn = Object.new.tap do |conn|
        conn.define_singleton_method(:exec_query) { |sql, _name = nil, binds = []| log << [sql, binds]; [] }
        conn.define_singleton_method(:quote_table_name) { |n| n }
      end
      ar_base = Class.new { define_singleton_method(:lease_connection) { fake_conn } }
      stub_const("ActiveRecord::Base", ar_base)

      Kiosk.configure do |c|
        c.kyc_issuer     = kyc_issuer
        c.kyc_public_key = kyc_key.public_key
        # The zero-config default idp verifies against the
        # provider's own signing key — configure one like a real install.
        c.signing_key    = Kiosk::Server::SigningKey.generate
        c.issuer         = "https://demo.example"
      end
    end

    def kyc_env
      # aud == the operator audience (defaults to c.issuer, "https://demo.example"),
      # so the engine's operator-binding check passes.
      body = JSON.generate(kyc_jws: JWT.encode(
        { sub: "u-kyc", level: "verified", iss: kyc_issuer, aud: "https://demo.example",
          iat: (Time.now - 5).to_i, exp: (Time.now + 600).to_i },
        kyc_key, "RS256",
      ))
      bearer_env("/kiosk/agents/kyc", "opaque-custom-token",
                 method: "POST", input: body, "CONTENT_TYPE" => "application/json")
    end

    it "authenticates via a custom configured agent_idp" do
      Kiosk.configure { |c| c.agent_idp = custom_idp }

      status, body = dispatch(Kiosk::Server::KycAttestationController, :create, kyc_env)
      expect(status).to eq(200)
      # A bare binary attestation (no `attributes`) verifies and returns the
      # empty attribute set — the anonymized named-attributes surface.
      expect(body).to eq(kyc_verified: true, attributes: {})
      # The row updated is the one for the CUSTOM idp's identity, and now also
      # persists the (empty) kyc_attributes jsonb alongside kyc_verified_at.
      sql, binds = executed_sql.last
      expect(sql).to include("kyc_attributes = $1::jsonb")
      expect(sql).to include("WHERE id = $2")
      expect(binds).to eq(["{}", "a-custom"])
    end

    it "records the named anonymized attributes an attestation carries" do
      Kiosk.configure { |c| c.agent_idp = custom_idp }

      body_json = JSON.generate(kyc_jws: JWT.encode(
        { sub: "u-kyc", level: "verified", iss: kyc_issuer, aud: "https://demo.example",
          iat: (Time.now - 5).to_i, exp: (Time.now + 600).to_i,
          attributes: { age_over_18: true, licence_a: true } },
        kyc_key, "RS256",
      ))
      env = bearer_env("/kiosk/agents/kyc", "opaque-custom-token",
                       method: "POST", input: body_json, "CONTENT_TYPE" => "application/json")

      status, body = dispatch(Kiosk::Server::KycAttestationController, :create, env)
      expect(status).to eq(200)
      # NB: the wire body is String-keyed JSON ({"age_over_18": true}); the
      # dispatch harness re-parses it with symbolize_names, hence Symbol keys here.
      expect(body).to eq(kyc_verified: true, attributes: { age_over_18: true, licence_a: true })
      # The persisted jsonb carries exactly the granted booleans — never a
      # document. It arrives as a BIND (K-782), so the payload is in the binds
      # and NOT in the statement text, and the `::jsonb` cast on the placeholder
      # is what makes it an object rather than a stored json string
      # (auth_plane_persistence_spec.rb proves that against a real Postgres).
      sql, binds = executed_sql.last
      expect(sql).to include("kyc_attributes = $1::jsonb")
      expect(sql).not_to include("age_over_18")
      expect(binds.first).to eq(JSON.generate("age_over_18" => true, "licence_a" => true))
    end

    it "does NOT fall back to user_idp — KYC is an agent-only surface" do
      Kiosk.configure { |c| c.user_idp = custom_idp }

      status, body = dispatch(Kiosk::Server::KycAttestationController, :create, kyc_env)
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    it "returns 401 for a foreign token under the zero-config default (bundled kiosk-pop idp)" do
      status, body = dispatch(Kiosk::Server::KycAttestationController, :create, kyc_env)
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    # An authenticated request with a malformed body must be a clean 400
    # BadRequest, not a 500. The parse previously ran outside the Errors::Base
    # rescue, so an empty body (JSON::ParserError) leaked as an unhandled 500.
    def kyc_env_with_body(input)
      bearer_env("/kiosk/agents/kyc", "opaque-custom-token",
                 method: "POST", input: input, "CONTENT_TYPE" => "application/json")
    end

    it "returns 400 BadRequest (not 500) for an EMPTY body on an authenticated request" do
      Kiosk.configure { |c| c.agent_idp = custom_idp }

      status, body = dispatch(Kiosk::Server::KycAttestationController, :create, kyc_env_with_body(""))
      expect_problem(status, body, http: 400, code: "bad_request")
    end

    it "returns 400 BadRequest (not 500) for a scalar/array body (TypeError on body[:kyc_jws])" do
      Kiosk.configure { |c| c.agent_idp = custom_idp }

      status, body = dispatch(Kiosk::Server::KycAttestationController, :create,
                              kyc_env_with_body("[1,2,3]"))
      expect_problem(status, body, http: 400, code: "bad_request")
    end

    # A well-formed JSON OBJECT that simply omits kyc_jws is a distinct
    # branch from the malformed-body ones above — it survives parse_body! and
    # hits `body[:kyc_jws] or raise BadRequest("missing field: kyc_jws")`.
    it "returns 400 BadRequest for a valid JSON object missing the kyc_jws field" do
      Kiosk.configure { |c| c.agent_idp = custom_idp }

      status, body = dispatch(Kiosk::Server::KycAttestationController, :create,
                              kyc_env_with_body(JSON.generate(not_kyc_jws: "x")))
      expect_problem(status, body, http: 400, code: "bad_request", detail: "kyc_jws")
    end
  end

  # ─── zero-config default idp + user_idp fallback on the wire ──
  describe "WireController identity resolution defaults" do
    before do
      Kiosk.configure do |c|
        c.signing_key = Kiosk::Server::SigningKey.generate
        c.issuer      = "https://demo.example"
        c.roles       = %i[customer]
        # NOTE: no agent_idp, no user_idp — zero-config install.
      end

      fake_conn = Object.new.tap do |conn|
        conn.define_singleton_method(:execute) { |_sql| [] }
        conn.define_singleton_method(:exec_query) { |_sql, _name = nil, _binds = []| [] }
        conn.define_singleton_method(:transaction) { |&blk| blk.call }
        conn.define_singleton_method(:quote_table_name) { |n| n }
      end
      # ONE reader now: `lease_connection` for the whole dispatch — the wire
      # controller (K-654) and the bundled DefaultAgentIdp (K-782) agree, and
      # `connection` is deliberately absent so a survivor would fail loudly.
      # `execute` is kept only so a stray caller does not NoMethodError: since
      # K-789 even SessionContext's GUCs go through `exec_query` binds
      # (`SELECT set_config($1, $2, true)` — `SET` itself takes no binds).
      ar_base = Class.new do
        define_singleton_method(:lease_connection) { fake_conn }
      end
      stub_const("ActiveRecord::Base", ar_base)
    end

    it "verifies a self-minted token with NO idp configured (bundled kiosk-pop default)" do
      token = Kiosk::Server::JwtIssuer.issue(
        claims:   { sub: "u-1", agent_id: "a-1", role: "customer", actor: "agent" },
        audience: "https://demo.example",
      )
      status, = dispatch(Kiosk::Server::WireController, :schema,
                         bearer_env("/kiosk/schema", token))
      expect(status).to eq(200)
    end

    it "still 401s garbage under the zero-config default" do
      status, body = dispatch(Kiosk::Server::WireController, :schema,
                              bearer_env("/kiosk/schema", "garbage"))
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    it "falls through to user_idp when the agent idp resolves nothing (no Authorization header)" do
      fixed = build_identity(actor: "human", agent_id: nil, user_id: "u-web")
      Kiosk.configure { |c| c.user_idp = Class.new { define_method(:verify) { |_r| fixed } }.new }

      status, = dispatch(Kiosk::Server::WireController, :schema,
                         Rack::MockRequest.env_for("/kiosk/schema"))
      expect(status).to eq(200)
    end
  end

  # ─── client-chosen requested_role is validated against roles ─────
  describe "OauthDeviceAuthorizationController requested_role validation" do
    let(:public_key) { OpenSSL::PKey::RSA.generate(2048).public_key.to_pem }

    before do
      Kiosk.configure do |c|
        c.roles = %i[customer]
        # The binding ceremony requires a public_key; pin the
        # in-memory store so these wire tests stay DB-free.
        c.device_authorization_store =
          Kiosk::Server::DeviceAuthorizationStores::InMemory.new
      end
    end

    def device_authorization_env(params)
      Rack::MockRequest.env_for("/kiosk/oauth/device_authorization",
                                method: "POST", params: { "public_key" => public_key }.merge(params))
    end

    it "rejects a role not among the configured roles with 400 invalid_request" do
      status, body = dispatch(
        Kiosk::Server::OauthDeviceAuthorizationController, :create,
        device_authorization_env("client_id" => "kiosk-cli", "role" => "superadmin"),
      )
      expect(status).to eq(400)
      expect(body[:error]).to eq("invalid_request")
      expect(body[:error_description]).to include("superadmin")
    end

    it "rejects an unknown role passed via the OAuth-standard scope param" do
      status, body = dispatch(
        Kiosk::Server::OauthDeviceAuthorizationController, :create,
        device_authorization_env("client_id" => "kiosk-cli", "scope" => "bogus"),
      )
      expect(status).to eq(400)
      expect(body[:error]).to eq("invalid_request")
    end

    it "accepts a configured role" do
      status, body = dispatch(
        Kiosk::Server::OauthDeviceAuthorizationController, :create,
        device_authorization_env("client_id" => "kiosk-cli", "role" => "customer"),
      )
      expect(status).to eq(200)
      expect(body[:device_code]).to be_a(String)
      expect(body[:user_code]).to match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
    end

    it "accepts a role-less request (role stays absent)" do
      status, body = dispatch(
        Kiosk::Server::OauthDeviceAuthorizationController, :create,
        device_authorization_env("client_id" => "kiosk-cli"),
      )
      expect(status).to eq(200)
      expect(body[:device_code]).to be_a(String)
    end
  end
end
