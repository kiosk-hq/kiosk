# frozen_string_literal: true

# The claim ceremony's human-facing verify page: session-
# authenticated via user_idp, shows what is being linked (key fingerprint +
# requested-at), approve/deny, attempt-capped code entry.
#
# Dispatch goes through `ActionController::Metal.action(...)` — no Rails
# host; spec_helper puts the engine views under app/views on the view path.

require 'rack/mock'
require 'openssl'

module DeviceVerifyControllerSpecHelpers
  VERIFY_URL = 'https://provider.example/kiosk/oauth/device/verify'

  # A user_idp whose #verify returns the given identity (or nil).
  def wire_user_idp(identity)
    idp = Class.new do
      def initialize(identity) = @identity = identity
      def verify(_request) = @identity
    end
    Kiosk.configure { |c| c.user_idp = idp.new(identity) }
  end

  def dispatch(action, method:, params: {}, headers: {})
    env = Rack::MockRequest.env_for(VERIFY_URL, method: method, params: params)
    headers.each { |k, v| env[k] = v }
    call_action(Kiosk::Server::DeviceVerifyController, action, env)
  end

  def dispatch_guarded(env_overrides)
    env = Rack::MockRequest.env_for(VERIFY_URL, method: 'POST')
    env_overrides.each { |k, v| env[k] = v }
    call_action(guarded, :create, env)
  end

  def call_action(controller, action, env)
    env['rack.session'] = session
    status, response_headers, body = controller.action(action).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, raw, response_headers]
  end

  # A claim ceremony opened by a registered client; `.start` reads its id and key only.
  def start_claim
    client = Kiosk::Server::Client.new(id: SecureRandom.uuid, user_id: 'assistant-account', public_key_pem: pem,
                                       allowed_roles: [], issued_at: 0)
    Kiosk::Server::DeviceCodeGrant.start(client: client)
  end
end

RSpec.shared_context 'with a holder signed in to the device verify page' do
  include DeviceVerifyControllerSpecHelpers

  let(:store)   { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:pem)     { OpenSSL::PKey.generate_key('ED25519').public_to_pem }
  let(:user_id) { '11111111-1111-1111-1111-111111111111' }
  let(:session) { {} }

  before do
    Kiosk.configure do |c|
      c.issuer                     = 'https://provider.example'
      c.roles                      = %i[customer]
      c.device_authorization_store = store
    end
    wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id))
  end
end

RSpec.describe 'DeviceVerifyController' do
  describe 'show' do
    include_context 'with a holder signed in to the device verify page'

    it 'renders the code-entry form for a signed-in account holder' do
      status, html = dispatch(:show, method: 'GET')
      expect(status).to eq(200)
      expect(html).to include('Enter the code')
    end

    it '401s a visitor with no provider session (sign in first)' do
      wire_user_idp(nil)
      status, body = dispatch(:show, method: 'GET')
      expect(status).to eq(401)
      expect(body).to include('Sign in')
    end

    it '401s when no user_idp is configured at all' do
      Kiosk.configure { |c| c.user_idp = nil }
      status, = dispatch(:show, method: 'GET')
      expect(status).to eq(401)
    end
  end

  # VERIFY-PAGE-UNAUTH-UX (K-1779): this page is the DEFAULT human step of the
  # claim ceremony — the `verification_uri` an assistant hands its human — so a
  # signed-out browser landing on it needs the same way forward its sibling
  # manage-assistants page has had. Both read `config.sign_in_path` through
  # {Kiosk::Server::AccountHolderGate}.
  describe 'with config.sign_in_path set (browser UX)' do
    include_context 'with a holder signed in to the device verify page'

    before do
      wire_user_idp(nil)
      Kiosk.configure { |c| c.sign_in_path = '/users/sign_in' }
    end

    it 'redirects an unauthenticated HTML request to the sign-in path (302) and stores return-to' do
      status, _body, headers = dispatch(:show, method: 'GET', headers: { 'HTTP_ACCEPT' => 'text/html' })
      expect(status).to eq(302)
      expect(headers['Location']).to end_with('/users/sign_in')
      expect(session['user_return_to']).to eq('/kiosk/oauth/device/verify')
    end

    # The flash mixin needs the flash MIDDLEWARE (present in a real Rails app;
    # absent in this bare Metal dispatch), so assert the controller ATTEMPTS to
    # set the alert rather than reading it back out of a serialised session.
    it 'sets a flash alert telling the visitor to sign in' do
      flash_double = {}
      controller = Kiosk::Server::DeviceVerifyController.new
      allow(controller).to receive(:flash).and_return(flash_double)
      allow(Kiosk::Server::DeviceVerifyController).to receive(:new).and_return(controller)
      dispatch(:show, method: 'GET', headers: { 'HTTP_ACCEPT' => 'text/html' })
      expect(flash_double[:alert]).to eq('Please sign in to approve the assistant link.')
    end

    # A non-HTML caller gets the 401, and the body names the sign-in page and
    # that a browser opening this page is sent there and back.
    it '401s a non-HTML request with a body naming the sign-in URL' do
      status, body = dispatch(:show, method: 'GET', headers: { 'HTTP_ACCEPT' => 'application/json' })
      expect(status).to eq(401)
      expect(body).to include('Sign in')
      expect(body).to include('https://provider.example/users/sign_in')
      expect(body).to include('https://provider.example/kiosk/oauth/device/verify')
    end
  end

  describe 'consent panel' do
    include_context 'with a holder signed in to the device verify page'

    it 'shows the consent panel with key fingerprint and requested-at for a live code' do
      start = start_claim
      status, html = dispatch(:show, method: 'GET', params: { 'user_code' => start[:user_code] })

      expect(status).to eq(200)
      expect(html).to include(Kiosk::Server::SigningKey.from_pem(pem).kid)
      expect(html).to include(start[:da].created_at.utc.to_s)
      expect(html).to include(%(value="approve"))
      expect(html).to include(%(value="deny"))
    end

    it "has no inline script or style, so a host policy of default-src 'self' holds" do
      _status, html = dispatch(:show, method: 'GET', params: { 'user_code' => start_claim[:user_code] })
      expect(html).not_to match(/<script|<style|\sstyle=|\son[a-z]+=/i)
    end

    # ── INFORMED CONSENT: the panel names the access being handed over ───────
    #
    # K-072's second half. The ceremony's role is the approver's own, so the
    # page can and must say which one — an approval given without seeing it is
    # not consent to anything in particular, and that is exactly the state the
    # page was in when a `role=owner` ceremony rendered a fingerprint and a
    # timestamp and nothing else.
    it 'names the role the approval hands over' do
      Kiosk.configure { |c| c.roles = %i[customer owner] }
      wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id, role: 'owner'))
      start = start_claim

      status, html = dispatch(:show, method: 'GET', params: { 'user_code' => start[:user_code] })
      expect(status).to eq(200)
      expect(html).to include('Access you are handing it')
      expect(html).to include('owner')
    end
  end

  describe 'consent panel without a role' do
    include_context 'with a holder signed in to the device verify page'

    it 'says so plainly when the provider gives the approver no role' do
      wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id, role: nil))
      start = start_claim

      _status, html = dispatch(:show, method: 'GET', params: { 'user_code' => start[:user_code] })
      expect(html).to include('Access you are handing it')
      # A short phrase on purpose: the template hard-wraps, so a longer literal
      # would be asserting the line breaks rather than the sentence.
      expect(html).to include('no separate access')
    end

    it 'reports an unknown code without leaking whether it ever existed' do
      status, html = dispatch(:show, method: 'GET', params: { 'user_code' => 'WDJB-MJHT' })
      expect(status).to eq(200)
      expect(html).to include('not recognised')
    end
  end

  describe 'approve' do
    include_context 'with a holder signed in to the device verify page'

    it "approve stamps the SESSION holder's user_id on the row" do
      start = start_claim
      status, html = dispatch(
        :create, method: 'POST',
                 params: { 'user_code' => start[:user_code], 'decision' => 'approve' }
      )

      expect(status).to eq(200)
      expect(html).to include('Approved')
      reloaded = store.lookup_by_device_code_hash(start[:da].device_code_hash)
      expect(reloaded).to be_approved
      expect(reloaded.user_id).to eq(user_id)
    end

    # THE FIX ITSELF (K-072). The role on the row is the SESSION holder's, and
    # it is the only role a claim ceremony can end up with: the authorization
    # request that created this row refuses to carry one.
    it "approve stamps the SESSION holder's ROLE on the row" do
      Kiosk.configure { |c| c.roles = %i[customer owner] }
      wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id, role: 'owner'))
      start = start_claim
      expect(start[:da].requested_role).to be_nil

      dispatch(
        :create, method: 'POST',
                 params: { 'user_code' => start[:user_code], 'decision' => 'approve' }
      )

      expect(store.lookup_by_device_code_hash(start[:da].device_code_hash).requested_role)
        .to eq('owner')
    end
  end

  describe 'approve without a role, and deny' do
    include_context 'with a holder signed in to the device verify page'

    it 'approve leaves the row role-less when the session holder has no role' do
      wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id, role: nil))
      start = start_claim

      dispatch(
        :create, method: 'POST',
                 params: { 'user_code' => start[:user_code], 'decision' => 'approve' }
      )

      expect(store.lookup_by_device_code_hash(start[:da].device_code_hash).requested_role).to be_nil
    end

    it 'deny marks the row denied' do
      start = start_claim
      status, html = dispatch(
        :create, method: 'POST',
                 params: { 'user_code' => start[:user_code], 'decision' => 'deny' }
      )

      expect(status).to eq(200)
      expect(html).to include('Denied')
      expect(store.lookup_by_device_code_hash(start[:da].device_code_hash)).to be_denied
    end
  end

  describe 'decision errors and attempt cap' do
    include_context 'with a holder signed in to the device verify page'

    it 'rejects an unknown decision' do
      status, = dispatch(
        :create, method: 'POST', params: { 'user_code' => 'X', 'decision' => 'hijack' }
      )
      expect(status).to eq(400)
    end

    it 're-renders with an error when the posted code no longer resolves' do
      status, html = dispatch(
        :create, method: 'POST', params: { 'user_code' => 'WDJB-MJHT', 'decision' => 'approve' }
      )
      expect(status).to eq(422)
      expect(html).to include('not recognised')
    end

    it 'caps failed code attempts per session (429 after the limit)' do
      max = Kiosk::Server::DeviceVerifyController::MAX_CODE_ATTEMPTS
      max.times do
        status, = dispatch(:show, method: 'GET', params: { 'user_code' => 'WDJB-MJHT' })
        expect(status).to eq(200)
      end

      status, body = dispatch(:show, method: 'GET', params: { 'user_code' => 'WDJB-MJHT' })
      expect(status).to eq(429)
      expect(body).to include('Too many')
    end
  end

  # The harness has no Rails app, so the subclass opts into `protect_from_forgery`
  # as every ActionController::Base of a Rails app does.
  describe 'forgery protection' do
    include_context 'with a holder signed in to the device verify page'

    let(:guarded) do
      stub_const(
        'ForgeryGuardedDeviceVerifyController',
        Class.new(Kiosk::Server::DeviceVerifyController) { protect_from_forgery with: :exception }
      )
    end

    it 'raises InvalidAuthenticityToken for a browser form POST and for a JSON POST' do
      expect { dispatch_guarded('HTTP_ACCEPT' => 'text/html') }
        .to raise_error(ActionController::InvalidAuthenticityToken)
      expect { dispatch_guarded('CONTENT_TYPE' => 'application/json', 'rack.input' => StringIO.new('{}')) }
        .to raise_error(ActionController::InvalidAuthenticityToken)
    end
  end
end
