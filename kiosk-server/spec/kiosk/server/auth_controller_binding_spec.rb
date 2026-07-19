# frozen_string_literal: true

# AuthController's link-flow endpoints: link (session-authed code
# mint), claim (register-shaped redeem), unlink (registration-layer
# revocation). Service semantics live in link_code_spec.rb /
# account_binding_spec.rb; here the controller contract is pinned — auth,
# envelopes, statuses.
#
# Mirrors controller_auth_spec.rb: actionpack pulled in, controller
# re-`load`ed, dispatch via `ActionController::Metal.action(...)`.

require "action_controller"
require "rack/mock"
require "json"

load File.expand_path("../../../lib/kiosk/server/auth_controller.rb", __dir__)

RSpec.describe "AuthController binding endpoints" do
  let(:store)   { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }
  let(:human)   { build_identity(actor: "human", agent_id: nil, user_id: user_id) }

  def wire_user_idp(identity)
    idp = Class.new do
      def initialize(identity) = @identity = identity
      def verify(_request) = @identity
    end
    Kiosk.configure { |c| c.user_idp = idp.new(identity) }
  end

  before do
    Kiosk.configure do |c|
      c.issuer                     = "https://provider.example"
      c.roles                      = %i[customer]
      c.device_authorization_store = store
    end
    wire_user_idp(human)
  end

  def dispatch(action, body: nil)
    opts = { method: "POST" }
    if body
      opts[:input] = JSON.generate(body)
      opts["CONTENT_TYPE"] = "application/json"
    end
    env = Rack::MockRequest.env_for("https://provider.example/kiosk/auth/#{action}", **opts)
    status, _headers, raw_body = Kiosk::Server::AuthController.action(action).call(env)
    raw = +""
    raw_body.each { |chunk| raw << chunk }
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  describe "POST /auth/link" do
    it "mints a single-use link code for the signed-in account holder (201)" do
      status, body = dispatch(:link)

      expect(status).to eq(201)
      expect(body[:link_code]).to be_a(String)
      expect(body[:expires_in]).to eq(Kiosk::Server::DeviceAuthorization::DEFAULT_EXPIRES_IN)

      row = store.find_by_device_code_hash(
        Kiosk::Server::DeviceAuthorization.hash_device_code(body[:link_code]),
      )
      expect(row).to be_approved
      expect(row).to be_link
      expect(row.user_id).to eq(user_id)
    end

    it "401s without a provider session — agent Bearer tokens do not open this door" do
      wire_user_idp(nil)
      status, body = dispatch(:link)
      expect(status).to eq(401)
      expect(body.dig(:error, :code)).to eq("unauthenticated")
    end
  end

  describe "POST /auth/claim" do
    it "delegates to LinkCode.redeem and returns the register-shaped 201" do
      allow(Kiosk::Server::LinkCode).to receive(:redeem).and_return(
        { agent_id: "a-1", user_id: user_id, access_token: "kiosk-pop-jwt" },
      )

      status, body = dispatch(:claim, body: { code: "c", public_key: "PEM", signed: "jws" })
      expect(status).to eq(201)
      expect(body).to eq(agent_id: "a-1", user_id: user_id, access_token: "kiosk-pop-jwt")
      expect(Kiosk::Server::LinkCode).to have_received(:redeem).with(
        code: "c", public_key_pem: "PEM", signed: "jws",
      )
    end

    it "400s on a missing field (register-shaped body: code, public_key, signed)" do
      status, body = dispatch(:claim, body: { code: "c", public_key: "PEM" })
      expect(status).to eq(400)
      expect(body.dig(:error, :message)).to match(/signed/)
    end

    it "maps a failed possession proof to the 401 envelope — code stays live" do
      allow(Kiosk::Server::LinkCode).to receive(:redeem)
        .and_raise(Kiosk::Server::Errors::Unauthenticated.new("proof signature invalid"))

      status, body = dispatch(:claim, body: { code: "c", public_key: "PEM", signed: "bad" })
      expect(status).to eq(401)
      expect(body.dig(:error, :code)).to eq("unauthenticated")
    end
  end

  describe "POST /auth/unlink" do
    it "deactivates one of the holder's own bindings" do
      allow(Kiosk::Server::AccountBinding).to receive(:unlink!).and_return({ agent_id: "a-1" })

      status, body = dispatch(:unlink, body: { agent_id: "a-1" })
      expect(status).to eq(200)
      expect(body).to eq(ok: true)
      expect(Kiosk::Server::AccountBinding).to have_received(:unlink!).with(
        agent_id: "a-1", user_id: user_id,
      )
    end

    it "401s without a provider session" do
      wire_user_idp(nil)
      status, = dispatch(:unlink, body: { agent_id: "a-1" })
      expect(status).to eq(401)
    end

    it "400s on a missing agent_id" do
      status, body = dispatch(:unlink, body: {})
      expect(status).to eq(400)
      expect(body.dig(:error, :message)).to match(/agent_id/)
    end

    it "404s for an agent not bound to this holder" do
      allow(Kiosk::Server::AccountBinding).to receive(:unlink!)
        .and_raise(Kiosk::Server::Errors::NotFound.new("no linked assistant account with this agent_id"))

      status, body = dispatch(:unlink, body: { agent_id: "foreign" })
      expect(status).to eq(404)
      expect(body.dig(:error, :code)).to eq("not_found")
    end
  end
end
