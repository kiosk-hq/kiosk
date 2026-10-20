# frozen_string_literal: true

# AuthController specs: #revoke and the guards of the auth surface.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host.

require 'rack/mock'
require 'json'

module AuthControllerSpecHelpers
  def dispatch(controller, action, env)
    status, headers, body = controller.action(action).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    @last_headers = headers
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  attr_reader :last_headers

  # The auth plane answers the SAME RFC 9457 problem document the wire does
  # since the 0.4 cutover: `application/problem+json` (the media type is half
  # of what makes a document a problem document), a per-code `type` URI and
  # `title`, the status restated in the body, and the SAME closed-vocabulary
  # token — moved from `error.code` to the TOP-LEVEL `code`, with the old
  # `message` as `detail`. SUCCESS bodies are untouched; they were never
  # enveloped.
  def expect_problem(status, body, http:, code:, detail: nil)
    expect(status).to eq(http)
    expect(last_headers['Content-Type']).to include('application/problem+json')
    expect_problem_members(body, http: http, code: code)
    expect(body[:detail]).to include(detail) if detail
  end

  def expect_problem_members(body, http:, code:)
    expect(body[:type]).to   eq("https://kiosk.tech/problems/#{code}")
    expect(body[:title]).to  eq(Kiosk::Server::Errors::TITLES.fetch(code))
    expect(body[:status]).to eq(http)
    expect(body[:code]).to   eq(code)
  end

  def revoke_env(token = nil)
    opts = { method: 'POST' }
    opts['HTTP_AUTHORIZATION'] = "Bearer #{token}" unless token.nil?
    Rack::MockRequest.env_for('/kiosk/auth/revoke', **opts)
  end

  # A fake connection whose #exec_query always answers the DefaultAgentIdp's
  # `SELECT user_id … WHERE id = $1` lookup (issue/verify both call it) with a
  # user row. No `quote`: since K-782 the IdP binds instead of quoting, so a
  # fake that offered one would hide a regression rather than catch it.
  def stub_agents_lookup(user_id: 'u-1')
    fake_conn = Object.new.tap do |conn|
      conn.define_singleton_method(:exec_query) { |_sql, _name = nil, _binds = []| [{ 'user_id' => user_id }] }
    end
    ar_base = Class.new { define_singleton_method(:lease_connection) { fake_conn } }
    stub_const('ActiveRecord::Base', ar_base)
  end

  def issue_token(agent_id)
    Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new.issue(
      agent_id: agent_id, role: 'customer'
    )
  end

  def verify_token(token)
    Kiosk::Server::JwtIssuer.verify(
      token: token,
      jwks: Kiosk::Server::Jwks.build(keys: [Kiosk.configuration.signing_key]),
      audience: 'https://demo.example',
      issuer: 'https://demo.example'
    )
  end

  def post_env(path, raw_body)
    Rack::MockRequest.env_for(path, method: 'POST', input: raw_body,
                                    'CONTENT_TYPE' => 'application/json')
  end

  def register(raw_body)
    dispatch(Kiosk::Server::AuthController, :register, post_env('/kiosk/auth/register', raw_body))
  end

  def login(raw_body)
    dispatch(Kiosk::Server::AuthController, :login, post_env('/kiosk/auth/login', raw_body))
  end
end

RSpec.shared_context 'auth controller spec: configured origin' do
  include AuthControllerSpecHelpers

  before do
    Kiosk.configure do |c|
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.issuer      = 'https://demo.example'
      c.roles       = %i[customer]
      c.agent_idp   = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
    end
  end
end

RSpec.describe Kiosk::Server::AuthController do
  include_context 'auth controller spec: configured origin'

  describe '#revoke (revoke-all-sessions)' do
    describe '401 guards' do
      # ─── 401 guard: nothing resolves (no / garbage token → nil identity) ─────
      it 'returns 401 Unauthenticated when NO Authorization header is present' do
        status, body = dispatch(described_class, :revoke, revoke_env)
        expect_problem(status, body, http: 401, code: 'unauthenticated')
      end

      it 'returns 401 Unauthenticated for a GARBAGE token (nil identity, not 500)' do
        status, body = dispatch(described_class, :revoke, revoke_env('garbage-not-a-jwt'))
        expect_problem(status, body, http: 401, code: 'unauthenticated')
      end

      # ─── 401 guard: identity resolves but carries NO agent_id ───────────────
      # A resolved-but-agentless identity (e.g. a human web session that somehow
      # reached this agent-only endpoint) must 401 rather than call revoke_all
      # with a nil agent_id. Only a custom idp can produce this shape — the
      # bundled DefaultAgentIdp's tokens always carry an agent_id.
      it 'returns 401 Unauthenticated when the resolved identity has a nil agent_id' do
        agentless = build_identity(actor: 'human', agent_id: nil, user_id: 'u-web')
        Kiosk.configure { |c| c.agent_idp = Class.new { define_method(:verify) { |_r| agentless } }.new }

        # revoke_all must NOT be reached for an agentless identity.
        expect(Kiosk.configuration.revocation_store).not_to receive(:revoke_all)

        status, body = dispatch(described_class, :revoke, revoke_env('some-token'))
        expect_problem(status, body, http: 401, code: 'unauthenticated')
      end
    end

    describe 'happy path' do
      # ─── happy path: revoke_all called, fresh token re-issued ───────────────
      it 'revokes all sessions for the caller and hands back a fresh usable token' do
        stub_agents_lookup(user_id: 'u-1')
        token = issue_token('a-1')

        expect(Kiosk.configuration.revocation_store)
          .to receive(:revoke_all).with('a-1', hash_including(:at)).and_call_original

        status, body = dispatch(described_class, :revoke, revoke_env(token))
        expect(status).to eq(200)
        expect(body).to match(access_token: a_kind_of(String))

        # The re-issued token must NOT itself be caught by the watermark it just
        # set: it verifies cleanly and resolves back to the same agent.
        claims = verify_token(body[:access_token])
        expect(claims[:agent_id]).to eq('a-1')
        expect(claims[:role]).to eq('customer')
      end

      it "puts the caller's original token under the revocation watermark" do
        stub_agents_lookup(user_id: 'u-1')
        token = issue_token('a-2')

        status, _body = dispatch(described_class, :revoke, revoke_env(token))
        expect(status).to eq(200)

        expect(Kiosk.configuration.revocation_store.revoked?(agent_id: 'a-2', iat: 0)).to be(true)
      end
    end
  end

  # ─── challenge / register / login HTTP-boundary error branches ─────
  #
  # The success paths of these actions are covered end-to-end by the auth-flow
  # and e2e specs; these examples pin the controller's OWN error guards — the
  # missing-public_key 400, missing-field 400, and malformed-body 400 — so they
  # render a clean 4xx problem document rather than escaping as a 500.
  describe 'auth-surface error branches' do
    # ─── GET /auth/challenge missing-public_key guard ───────────────────────
    describe '#challenge' do
      it 'returns 400 bad_request when public_key is absent' do
        env = Rack::MockRequest.env_for('/kiosk/auth/challenge')
        status, body = dispatch(described_class, :challenge, env)
        expect_problem(status, body, http: 400, code: 'bad_request', detail: 'public_key')
      end

      it 'returns 400 bad_request when public_key is blank' do
        env = Rack::MockRequest.env_for('/kiosk/auth/challenge?public_key=')
        status, body = dispatch(described_class, :challenge, env)
        expect_problem(status, body, http: 400, code: 'bad_request')
      end
    end

    # ─── POST /auth/register body/field guards ──────────────────────────────
    describe '#register' do
      it 'returns 400 bad_request for an EMPTY body (not 500)' do
        status, body = register('')
        expect_problem(status, body, http: 400, code: 'bad_request')
      end

      it 'returns 400 bad_request for INVALID JSON (not 500)' do
        status, body = register('{not valid json')
        expect_problem(status, body, http: 400, code: 'bad_request')
      end

      it 'returns 400 bad_request for a non-object JSON body (not 500)' do
        status, body = register('[1,2,3]')
        expect_problem(status, body, http: 400, code: 'bad_request')
      end

      it 'returns 400 bad_request naming the missing field when public_key is omitted' do
        status, body = register(JSON.generate(signed: 'x'))
        expect_problem(status, body, http: 400, code: 'bad_request', detail: 'public_key')
      end

      it 'returns 400 bad_request naming the missing field when signed is omitted' do
        status, body = register(JSON.generate(public_key: 'x'))
        expect_problem(status, body, http: 400, code: 'bad_request', detail: 'signed')
      end
    end

    describe '#register wrong-typed public_key' do
      # A wrong-TYPED public_key (not just a missing one — the missing-field
      # branch covered only missing fields) must render a clean 400, not escape as a 500. A JSON
      # number / object / array field reaches AgentRegistration as an Integer /
      # Hash / Array; `.to_s.strip` coerces it so PopVerifier rejects it as an
      # invalid key with a 400 problem document instead of NoMethodError-ing on
      # `.strip`. (`expect_problem` above is why the shape is named that way: the
      # token is the TOP-LEVEL `code`, not `error.code`.)
      it 'returns 400 bad_request (not 500) when public_key is a NUMBER' do
        status, body = register(JSON.generate(public_key: 12_345, signed: 'x'))
        expect_problem(status, body, http: 400, code: 'bad_request')
      end

      it 'returns 400 bad_request (not 500) when public_key is an OBJECT' do
        status, body = register(JSON.generate(public_key: { k: 'v' }, signed: 'x'))
        expect_problem(status, body, http: 400, code: 'bad_request')
      end

      it 'returns 400 bad_request (not 500) when public_key is an ARRAY' do
        status, body = register(JSON.generate(public_key: [1, 2], signed: 'x'))
        expect_problem(status, body, http: 400, code: 'bad_request')
      end
    end

    # ─── POST /auth/login body/field guards ─────────────────────────────────
    describe '#login' do
      it 'returns 400 bad_request for an EMPTY body (not 500)' do
        status, body = login('')
        expect_problem(status, body, http: 400, code: 'bad_request')
      end

      it 'returns 400 bad_request for INVALID JSON (not 500)' do
        status, body = login('{not valid json')
        expect_problem(status, body, http: 400, code: 'bad_request')
      end

      it 'returns 400 bad_request naming the missing field when signed is omitted' do
        status, body = login(JSON.generate(public_key: 'x'))
        expect_problem(status, body, http: 400, code: 'bad_request', detail: 'signed')
      end

      # The same wrong-typed-field guard on the login sibling.
      it 'returns 400 bad_request (not 500) when public_key is a NUMBER' do
        status, body = login(JSON.generate(public_key: 12_345, signed: 'x'))
        expect_problem(status, body, http: 400, code: 'bad_request')
      end

      it 'returns 400 bad_request (not 500) when public_key is an OBJECT' do
        status, body = login(JSON.generate(public_key: { k: 'v' }, signed: 'x'))
        expect_problem(status, body, http: 400, code: 'bad_request')
      end
    end
  end
end
