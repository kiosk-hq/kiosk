# frozen_string_literal: true

# AuthController's link-flow endpoints: link (session-authed code
# mint), claim (register-shaped redeem), unlink (registration-layer
# revocation). Service semantics live in link_code_spec.rb /
# account_binding_spec.rb; here the controller contract is pinned — auth,
# statuses, and the RFC 9457 problem document every refusal is since 0.4.
#
# Dispatch via `ActionController::Metal.action(...)`.

require "rack/mock"
require "json"

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
    status, headers, raw_body = Kiosk::Server::AuthController.action(action).call(env)
    raw = +""
    raw_body.each { |chunk| raw << chunk }
    @last_headers = headers
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  def last_headers = @last_headers

  # Every REFUSAL on this surface is an RFC 9457 problem document since the
  # 0.4 cutover — `application/problem+json`, a per-code `type` and `title`,
  # the status restated in the body, and the SAME closed-vocabulary token,
  # now at the TOP level as `code` rather than under `error.code`. The old
  # `message` is `detail`. Successes are untouched: they were never enveloped.
  def expect_problem(status, body, http:, code:, detail: nil)
    expect(status).to eq(http)
    expect(last_headers["Content-Type"]).to include("application/problem+json")
    expect(body[:type]).to   eq("https://kiosk.tech/problems/#{code}")
    expect(body[:title]).to  eq(Kiosk::Server::Errors::TITLES.fetch(code))
    expect(body[:status]).to eq(http)
    expect(body[:code]).to   eq(code)
    expect(body[:detail]).to match(detail) if detail
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
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    # roles-from-IdP (Path A): the human's role — as the provider's
    # user_idp reports it on the session identity — is captured onto the link
    # row, so the assistant that redeems it inherits the human's role.
    it "captures the human's user_idp role onto the link row (roles-from-IdP)" do
      Kiosk.configure { |c| c.roles = %i[customer owner] }
      wire_user_idp(build_identity(actor: "human", agent_id: nil, user_id: user_id, role: "owner"))

      _status, body = dispatch(:link)
      row = store.find_by_device_code_hash(
        Kiosk::Server::DeviceAuthorization.hash_device_code(body[:link_code]),
      )
      expect(row.requested_role).to eq("owner")
    end

    it "captures no role for a role-less human session (no regression)" do
      wire_user_idp(build_identity(actor: "human", agent_id: nil, user_id: user_id, role: nil))

      _status, body = dispatch(:link)
      row = store.find_by_device_code_hash(
        Kiosk::Server::DeviceAuthorization.hash_device_code(body[:link_code]),
      )
      expect(row.requested_role).to be_nil
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
      expect_problem(status, body, http: 400, code: "bad_request", detail: /signed/)
    end

    it "maps a failed possession proof to the 401 problem document — code stays live" do
      allow(Kiosk::Server::LinkCode).to receive(:redeem)
        .and_raise(Kiosk::Server::Errors::Unauthenticated.new("proof signature invalid"))

      status, body = dispatch(:claim, body: { code: "c", public_key: "PEM", signed: "bad" })
      expect_problem(status, body, http: 401, code: "unauthenticated",
                     detail: /proof signature invalid/)
    end

    # K-855. `AccountBinding.bind!` — which is what `redeem` returns — also
    # carries `fresh:`, an internal fresh-key-vs-rebind signal that NO published
    # surface documents (zero hits in protocol.md, specification.html, skill.md
    # or the schemas) and that §6.2 contradicts by spelling the response out as
    # {agent_id, user_id, access_token}. It was on the wire on every claim
    # because the controller rendered the result hash whole. The example above
    # could not catch it: it stubs a return value that does not have the field.
    # This one stubs what the service actually returns.
    it "renders only the three fields §6.2 specifies — bind!'s `fresh` never reaches the wire" do
      allow(Kiosk::Server::LinkCode).to receive(:redeem).and_return(
        { agent_id: "a-1", user_id: user_id, access_token: "kiosk-pop-jwt", fresh: false },
      )

      status, body = dispatch(:claim, body: { code: "c", public_key: "PEM", signed: "jws" })
      expect(status).to eq(201)
      expect(body.keys).to contain_exactly(:agent_id, :user_id, :access_token)
      expect(body).not_to have_key(:fresh)
    end

    # The same, for the OTHER branch: a FRESH key. §6.3 requires that a rebind
    # be indistinguishable from any other rebind (K-787); a `fresh` flag is the
    # field an assistant would reach for to distinguish binds at all, so it must
    # be absent whichever branch produced the result.
    it "renders the same three fields for a fresh-key bind" do
      allow(Kiosk::Server::LinkCode).to receive(:redeem).and_return(
        { agent_id: "a-2", user_id: user_id, access_token: "kiosk-pop-jwt", fresh: true },
      )

      _status, body = dispatch(:claim, body: { code: "c", public_key: "PEM", signed: "jws" })
      expect(body.keys).to contain_exactly(:agent_id, :user_id, :access_token)
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
      status, body = dispatch(:unlink, body: { agent_id: "a-1" })
      expect_problem(status, body, http: 401, code: "unauthenticated")
    end

    it "400s on a missing agent_id" do
      status, body = dispatch(:unlink, body: {})
      expect_problem(status, body, http: 400, code: "bad_request", detail: /agent_id/)
    end

    it "404s for an agent not bound to this holder" do
      allow(Kiosk::Server::AccountBinding).to receive(:unlink!)
        .and_raise(Kiosk::Server::Errors::NotFound.new("no linked assistant account with this agent_id"))

      status, body = dispatch(:unlink, body: { agent_id: "foreign" })
      expect_problem(status, body, http: 404, code: "not_found",
                     detail: /no linked assistant account/)
    end
  end
end
