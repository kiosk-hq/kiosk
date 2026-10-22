# frozen_string_literal: true

# AuthController's link-flow endpoints: link (session-authed code
# mint), claim (a redeem by a registered client), unlink (registration-layer
# revocation). Service semantics live in link_code_spec.rb /
# account_binding_spec.rb; here the controller contract is pinned — auth,
# statuses, and the RFC 9457 problem document every refusal is since 0.4.
#
# Dispatch via `ActionController::Metal.action(...)`.

require 'rack/mock'
require 'json'

module AuthControllerBindingSpecHelpers
  def wire_user_idp(identity)
    idp = Class.new do
      def initialize(identity) = @identity = identity
      def verify(_request) = @identity
    end
    Kiosk.configure { |c| c.user_idp = idp.new(identity) }
  end

  def dispatch(action, body: nil, content_type: 'application/json')
    env = binding_env(action, body, content_type)
    status, headers, raw_body = Kiosk::Server::AuthController.action(action).call(env)
    raw = +''
    raw_body.each { |chunk| raw << chunk }
    @last_headers = headers
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  def binding_env(action, body, content_type)
    opts = { method: 'POST', 'CONTENT_TYPE' => content_type }
    opts[:input] = JSON.generate(body) if body
    Rack::MockRequest.env_for("https://provider.example/kiosk/auth/#{action}", **opts)
  end

  attr_reader :last_headers

  # Every REFUSAL on this surface is an RFC 9457 problem document since the
  # 0.4 cutover — `application/problem+json`, a per-code `type` and `title`,
  # the status restated in the body, and the SAME closed-vocabulary token,
  # now at the TOP level as `code` rather than under `error.code`. The old
  # `message` is `detail`. Successes are untouched: they were never enveloped.
  def expect_problem(status, body, http:, code:, detail: nil)
    expect(status).to eq(http)
    expect(last_headers['Content-Type']).to include('application/problem+json')
    expect_problem_members(body, http: http, code: code)
    expect(body[:detail]).to match(detail) if detail
  end

  def expect_problem_members(body, http:, code:)
    expect(body[:type]).to   eq("https://kiosk.tech/problems/#{code}")
    expect(body[:title]).to  eq(Kiosk::Server::Errors::TITLES.fetch(code))
    expect(body[:status]).to eq(http)
    expect(body[:code]).to   eq(code)
  end

  def link_row(link_code)
    store.lookup_by_device_code_hash(
      Kiosk::Server::DeviceAuthorization.hash_device_code(link_code)
    )
  end
end

RSpec.shared_context 'with a holder signed in to the auth controller' do
  include AuthControllerBindingSpecHelpers

  let(:store)   { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:user_id) { '11111111-1111-1111-1111-111111111111' }
  let(:human)   { build_identity(actor: 'human', agent_id: nil, user_id: user_id) }

  before do
    Kiosk.configure do |c|
      c.issuer                     = 'https://provider.example'
      c.roles                      = %i[customer]
      c.device_authorization_store = store
    end
    wire_user_idp(human)
  end
end

RSpec.describe Kiosk::Server::AuthController do
  describe 'binding endpoints' do
    describe 'POST /auth/link' do
      include_context 'with a holder signed in to the auth controller'

      it 'mints a single-use link code for the signed-in account holder (201)' do
        status, body = dispatch(:link)

        expect(status).to eq(201)
        expect(body[:link_code]).to be_a(String)
        expect(body[:expires_in]).to eq(Kiosk::Server::DeviceAuthorization::DEFAULT_EXPIRES_IN)

        row = link_row(body[:link_code])
        expect(row).to be_approved
        expect(row).to be_link
        expect(row.user_id).to eq(user_id)
      end

      it '401s without a provider session — agent Bearer tokens do not open this door' do
        wire_user_idp(nil)
        status, body = dispatch(:link)
        expect_problem(status, body, http: 401, code: 'unauthenticated')
        expect(last_headers['WWW-Authenticate']).to eq('Kiosk-Session realm="https://provider.example"')
      end
    end

    describe 'POST /auth/link roles-from-IdP' do
      include_context 'with a holder signed in to the auth controller'

      # roles-from-IdP (Path A): the human's role — as the provider's
      # user_idp reports it on the session identity — is captured onto the link
      # row, so the assistant that redeems it inherits the human's role.
      it "captures the human's user_idp role onto the link row (roles-from-IdP)" do
        Kiosk.configure { |c| c.roles = %i[customer owner] }
        wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id, role: 'owner'))

        _status, body = dispatch(:link)
        row = link_row(body[:link_code])
        expect(row.requested_role).to eq('owner')
      end

      it 'captures no role for a role-less human session (no regression)' do
        wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id, role: nil))

        _status, body = dispatch(:link)
        row = link_row(body[:link_code])
        expect(row.requested_role).to be_nil
      end
    end

    describe 'POST /auth/claim' do
      include_context 'with a holder signed in to the auth controller'

      let(:claim_body) do
        { code: 'c', client_assertion_type: Kiosk::Server::ClientAssertion::TYPE, client_assertion: 'jws' }
      end

      it 'delegates to LinkCode.redeem and answers 204 with no body' do
        allow(Kiosk::Server::LinkCode).to receive(:redeem)

        status, body = dispatch(:claim, body: claim_body)
        expect([status, body]).to eq([204, {}])
        expect(Kiosk::Server::LinkCode).to have_received(:redeem).with(
          code: 'c', assertion_type: Kiosk::Server::ClientAssertion::TYPE, assertion: 'jws', pow: nil
        )
      end

      it '400s on a missing field' do
        status, body = dispatch(:claim, body: claim_body.except(:client_assertion))
        expect_problem(status, body, http: 400, code: 'bad_request', detail: /client_assertion/)
      end

      it 'maps a refused client assertion to the 401 problem document, with the hint' do
        allow(Kiosk::Server::LinkCode).to receive(:redeem)
          .and_raise(Kiosk::Server::ClientAssertion::Refused.new('client assertion signature invalid', hint: 'sign it'))

        status, body = dispatch(:claim, body: claim_body)
        expect_problem(status, body, http: 401, code: 'unauthenticated', detail: /signature invalid/)
        expect(body[:hint]).to eq('sign it')
        expect(last_headers['WWW-Authenticate']).to eq('Kiosk-Client-Assertion realm="https://provider.example"')
      end
    end

    describe 'POST /auth/claim against the agents table' do
      include_context 'with registered clients'
      include AuthControllerBindingSpecHelpers

      let(:store)  { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
      let(:client) { register_client }

      before { Kiosk.configure { |c| c.device_authorization_store = store } }

      # [status, body, headers] of a claim of a link code that `user_id` mints.
      def claim_for(user_id)
        code = Kiosk::Server::LinkCode.mint(user_id: user_id, requested_role: 'customer', store: store)[:link_code]
        status, body = dispatch(:claim, body: { code: code, client_assertion_type: Kiosk::Server::ClientAssertion::TYPE,
                                                client_assertion: client_assertion(client.id) })
        [status, body, last_headers]
      end

      def watermark = Kiosk.configuration.revocation_store.watermark_for(client.id)

      # §6.3: the operator MUST NOT treat a rebind to the same account specially.
      it 'answers a rebind to the same account as a rebind from another account, and stamps the watermark again' do
        holder = holder!
        from_another = claim_for(holder)
        stamped = watermark
        to_same = claim_for(holder)

        expect(from_another.first).to eq(204)
        expect(to_same).to eq(from_another)
        expect(watermark).to be > stamped
      end
    end

    describe 'POST /auth/unlink' do
      include_context 'with a holder signed in to the auth controller'

      # 204, EMPTY (K-870). This used to be `200 {ok: true}` — a body no published
      # surface documented, on an endpoint whose two siblings above ARE documented
      # in protocol.md §6.2. K-855 settled it the other way: withdraw the body
      # rather than specify it after the fact. §6.2 now states the 204, so the status IS
      # the contract and this example is what pins it.
      it "deactivates one of the holder's own bindings and answers 204 with no body" do
        allow(Kiosk::Server::AccountBinding).to receive(:unlink!).and_return({ agent_id: 'a-1' })

        status, body = dispatch(:unlink, body: { agent_id: 'a-1' })
        expect(status).to eq(204)
        expect(body).to eq({})
        expect(last_headers['Content-Type']).to be_nil
        # The version handshake still rides on it — §3, point 6 is about every
        # mount-path response, empty ones included.
        expect(last_headers['Kiosk-API-Version']).to eq(Kiosk::Protocol::API_VERSION)
        expect(Kiosk::Server::AccountBinding).to have_received(:unlink!).with(
          agent_id: 'a-1', user_id: user_id
        )
      end

      it '401s without a provider session' do
        wire_user_idp(nil)
        status, body = dispatch(:unlink, body: { agent_id: 'a-1' })
        expect_problem(status, body, http: 401, code: 'unauthenticated')
        expect(last_headers['WWW-Authenticate']).to eq('Kiosk-Session realm="https://provider.example"')
      end
    end

    describe 'a session request that is not JSON' do
      include_context 'with a holder signed in to the auth controller'

      # A page on a sibling subdomain is same-site: its `text/plain` form carries
      # the holder's cookie and needs no CORS preflight.
      it 'refuses an unlink posted as a form, and unlinks nothing' do
        allow(Kiosk::Server::AccountBinding).to receive(:unlink!)

        status, body = dispatch(:unlink, body: { agent_id: 'a-1' }, content_type: 'text/plain')
        expect_problem(status, body, http: 400, code: 'bad_request', detail: %r{application/json})
        expect(Kiosk::Server::AccountBinding).not_to have_received(:unlink!)
      end

      it 'refuses a link posted as a form' do
        status, body = dispatch(:link, content_type: 'application/x-www-form-urlencoded')
        expect_problem(status, body, http: 400, code: 'bad_request', detail: %r{application/json})
      end
    end

    describe 'POST /auth/unlink request errors' do
      include_context 'with a holder signed in to the auth controller'

      it '400s on a missing agent_id' do
        status, body = dispatch(:unlink, body: {})
        expect_problem(status, body, http: 400, code: 'bad_request', detail: /agent_id/)
      end

      it '404s for an agent not bound to this holder' do
        allow(Kiosk::Server::AccountBinding).to receive(:unlink!)
          .and_raise(Kiosk::Server::Errors::NotFound.new('no linked assistant account with this agent_id'))

        status, body = dispatch(:unlink, body: { agent_id: 'foreign' })
        expect_problem(status, body, http: 404, code: 'not_found',
                                     detail: /no linked assistant account/)
      end
    end
  end
end
