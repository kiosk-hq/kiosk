# frozen_string_literal: true

# The claim ceremony's human-facing verify page: session-
# authenticated via user_idp, shows what is being linked (key fingerprint +
# requested-at), approve/deny, attempt-capped code entry.
#
# Mirrors controller_auth_spec.rb: actionpack is pulled in here and the
# controller re-`load`ed to materialise the class (spec_helper requires
# kiosk/server before actionpack exists). Dispatch goes through
# `ActionController::Metal.action(...)` — no Rails host; the engine views
# under app/views are resolved via the controller's append_view_path.

require "action_controller"
require "rack/mock"
require "openssl"

load File.expand_path("../../../lib/kiosk/server/device_verify_controller.rb", __dir__)

RSpec.describe "DeviceVerifyController" do
  let(:store)   { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:rsa)     { OpenSSL::PKey::RSA.generate(2048) }
  let(:pem)     { rsa.public_key.to_pem }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }
  let(:session) { {} }

  # A user_idp whose #verify returns the given identity (or nil).
  def wire_user_idp(identity)
    idp = Class.new do
      def initialize(identity) = @identity = identity
      def verify(_request) = @identity
    end
    Kiosk.configure { |c| c.user_idp = idp.new(identity) }
  end

  let(:human) { build_identity(actor: "human", agent_id: nil, user_id: user_id) }

  before do
    Kiosk.configure do |c|
      c.issuer                     = "https://provider.example"
      c.roles                      = %i[customer]
      c.device_authorization_store = store
    end
    wire_user_idp(human)
  end

  def dispatch(action, method:, params: {})
    env = Rack::MockRequest.env_for(
      "https://provider.example/kiosk/oauth/device/verify",
      method: method, params: params,
    )
    env["rack.session"] = session
    status, _headers, body = Kiosk::Server::DeviceVerifyController.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, raw]
  end

  def start_claim
    Kiosk::Server::DeviceCodeGrant.start(client_id: "assistant", public_key_pem: pem)
  end

  it "renders the code-entry form for a signed-in account holder" do
    status, html = dispatch(:show, method: "GET")
    expect(status).to eq(200)
    expect(html).to include("Enter the code")
  end

  it "401s a visitor with no provider session (sign in first)" do
    wire_user_idp(nil)
    status, body = dispatch(:show, method: "GET")
    expect(status).to eq(401)
    expect(body).to include("Sign in")
  end

  it "401s when no user_idp is configured at all" do
    Kiosk.configure { |c| c.user_idp = nil }
    status, = dispatch(:show, method: "GET")
    expect(status).to eq(401)
  end

  it "shows the consent panel with key fingerprint and requested-at for a live code" do
    start = start_claim
    status, html = dispatch(:show, method: "GET", params: { "user_code" => start[:user_code] })

    expect(status).to eq(200)
    expect(html).to include(Kiosk::Server::SigningKey.from_pem(pem).kid)
    expect(html).to include(start[:da].created_at.utc.to_s)
    expect(html).to include(%(value="approve"))
    expect(html).to include(%(value="deny"))
  end

  it "reports an unknown code without leaking whether it ever existed" do
    status, html = dispatch(:show, method: "GET", params: { "user_code" => "WDJB-MJHT" })
    expect(status).to eq(200)
    expect(html).to include("not recognised")
  end

  it "approve stamps the SESSION holder's user_id on the row" do
    start = start_claim
    status, html = dispatch(
      :create, method: "POST",
      params: { "user_code" => start[:user_code], "decision" => "approve" },
    )

    expect(status).to eq(200)
    expect(html).to include("Approved")
    reloaded = store.find_by_device_code_hash(start[:da].device_code_hash)
    expect(reloaded).to be_approved
    expect(reloaded.user_id).to eq(user_id)
  end

  it "deny marks the row denied" do
    start = start_claim
    status, html = dispatch(
      :create, method: "POST",
      params: { "user_code" => start[:user_code], "decision" => "deny" },
    )

    expect(status).to eq(200)
    expect(html).to include("Denied")
    expect(store.find_by_device_code_hash(start[:da].device_code_hash)).to be_denied
  end

  it "rejects an unknown decision" do
    status, = dispatch(
      :create, method: "POST", params: { "user_code" => "X", "decision" => "hijack" },
    )
    expect(status).to eq(400)
  end

  it "re-renders with an error when the posted code no longer resolves" do
    status, html = dispatch(
      :create, method: "POST", params: { "user_code" => "WDJB-MJHT", "decision" => "approve" },
    )
    expect(status).to eq(422)
    expect(html).to include("not recognised")
  end

  it "caps failed code attempts per session (429 after the limit)" do
    max = Kiosk::Server::DeviceVerifyController::MAX_CODE_ATTEMPTS
    max.times do
      status, = dispatch(:show, method: "GET", params: { "user_code" => "WDJB-MJHT" })
      expect(status).to eq(200)
    end

    status, body = dispatch(:show, method: "GET", params: { "user_code" => "WDJB-MJHT" })
    expect(status).to eq(429)
    expect(body).to include("Too many")
  end

  # ── AGENT-SIGNPOST, the forgery-protection path (K-459) ───────────────────
  # Same story as AssistantsController (its spec carries the long version): an
  # assistant POSTing JSON to this human consent page has no CSRF token, and in
  # production the resulting InvalidAuthenticityToken becomes a BODYLESS 422
  # (text/html, Content-Length 0). The harness has no Rails app, so the
  # subclass opts into `protect_from_forgery` to reproduce that condition.
  describe "forgery protection on a JSON POST" do
    let(:guarded) do
      stub_const(
        "ForgeryGuardedDeviceVerifyController",
        Class.new(Kiosk::Server::DeviceVerifyController) { protect_from_forgery with: :exception },
      )
    end

    def dispatch_guarded(env_overrides)
      env = Rack::MockRequest.env_for(
        "https://provider.example/kiosk/oauth/device/verify", method: "POST",
      )
      env_overrides.each { |k, v| env[k] = v }
      env["rack.session"] = session
      status, headers, body = guarded.action(:create).call(env)
      raw = +""
      body.each { |chunk| raw << chunk }
      [status, raw, headers]
    end

    it "answers a JSON-bodied POST with the error envelope and a pointer to the wire" do
      status, body, headers = dispatch_guarded(
        "CONTENT_TYPE" => "application/json", "rack.input" => StringIO.new("{}"),
      )

      expect(status).to eq(422)
      expect(headers["Content-Type"]).to include("application/json")
      expect(body).not_to be_empty
      envelope = JSON.parse(body)
      expect(envelope["ok"]).to be(false)
      expect(envelope.dig("error", "code")).to eq("invalid_authenticity_token")
      expect(envelope.dig("error", "hint"))
        .to include("https://provider.example/.well-known/kiosk.json")
    end

    it "still raises for a browser form POST — the CSRF gate is unchanged" do
      expect { dispatch_guarded("HTTP_ACCEPT" => "text/html") }
        .to raise_error(::ActionController::InvalidAuthenticityToken)
    end
  end
end
