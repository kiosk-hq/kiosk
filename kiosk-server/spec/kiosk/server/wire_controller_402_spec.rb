# frozen_string_literal: true

# WireController 402 WWW-Authenticate header specs.
#
# De-overloading the two 402 gates: the `WWW-Authenticate` response header
# NAMES the gate (Kiosk-PoW vs Payment) so a client can disambiguate at the
# header level, while the JSON body STILL carries the structured payload (the
# PoW N-challenge list / the payment_setup pointer). Both 402s render through
# WireController#render_wire_error as an RFC 9457 problem document served as
# `application/problem+json`, so the code a client branches on is the
# TOP-LEVEL `code` member and the hint/challenges payload rides alongside it as
# extension members.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host.

require 'rack/mock'
require 'json'
require 'kiosk/pow/argon2id'
require 'kiosk/reputation'

module WireController402Spec
  # Challenges every verb with a fast argon2id toll.
  class AlwaysChallengePolicy < Kiosk::Reputation::Policy
    def challenge_for(**) = { alg: 'argon2id', params: Kiosk::Pow::Argon2id.params(d: 4, m: 8) }
  end

  def dispatch(action, env)
    finish(Kiosk::Server::WireController.action(action).call(env))
  end

  def dispatch_verb(action, name, env)
    env['action_dispatch.request.path_parameters'] =
      { controller: 'kiosk/server/verb', action: action.to_s, kiosk_verb: name }
    finish(Kiosk::Server::VerbController.action(action).call(env))
  end

  def finish(rack_triplet)
    status, headers, body = rack_triplet
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  # `path` carrying `token` and its DPoP proof for this method on this origin.
  def token_env(path, token, **opts)
    proof = dpop_env(token, method: opts.fetch(:method, 'GET'), url: "https://demo.example#{path}")
    Rack::MockRequest.env_for(path, **proof, **opts)
  end

  # `POST /kiosk/pay` with three placeholder mandates.
  def pay_env
    token_env('/kiosk/pay', agent_token,
              method: 'POST', 'CONTENT_TYPE' => 'application/json',
              input: JSON.generate(checkout_mandate: 'x~', payment_mandate: 'y~'))
  end

  def agent_token
    Kiosk::Server::JwtIssuer.issue(
      claims: { sub: 'u-1', agent_id: 'a-1', role: 'customer', actor: 'agent', cnf: cnf_for },
      audience: 'https://demo.example'
    )
  end
end

RSpec.shared_context 'with an origin for WireController' do
  include WireController402Spec

  before do
    Kiosk.configure do |c|
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.issuer      = 'https://demo.example'
      c.roles       = %i[customer]
      c.agent_idp   = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
    end
  end
end

RSpec.shared_context 'with a proof-of-work toll on WireController' do
  before do
    Kiosk::Reputation::Backends.register('argon2id', Kiosk::Pow::Argon2id)
    Kiosk.configure do |c|
      c.reputation_policy = WireController402Spec::AlwaysChallengePolicy.new
      c.pow_secret        = 'test-pow-secret-of-at-least-32-bytes'
    end
  end

  after { Kiosk::Reputation::Backends.reset! }
end

RSpec.describe Kiosk::Server::WireController do
  describe '402 WWW-Authenticate (W4)' do
    include_context 'with an origin for WireController'

    # ─── The toll → WWW-Authenticate: Kiosk-PoW ────────────────────────────
    describe 'the pow_required 402' do
      include_context 'with a proof-of-work toll on WireController'

      # The reserved plane pays the same toll and answers the same way as the
      # per-verb wire: one answer shape on every Kiosk endpoint, here
      # `POST <endpoint>/pay` for the toll.
      it 'carries WWW-Authenticate: Kiosk-PoW AND the challenges, on the reserved POST pay' do
        status, headers, problem = dispatch(:pay, pay_env)
        expect(status).to eq(402)
        expect(headers['WWW-Authenticate']).to eq('Kiosk-PoW realm="https://demo.example"')
        expect(headers['Content-Type']).to include('application/problem+json')
        # Body payload preserved (header names, body carries).
        expect(problem[:code]).to   eq('pow_required')
        expect(problem[:type]).to   eq('https://kiosk.tech/problems/pow_required')
        expect(problem[:status]).to eq(402)
        expect(problem[:challenges]).to be_an(Array)
        expect(problem[:challenges]).not_to be_empty
        expect(problem).not_to have_key(:ok)
        expect(problem).not_to have_key(:error)
      end

      # The same gate on the per-verb wire: the header names the gate, the
      # challenges ride in the body, and the code an assistant branches on is
      # `pow_required`, a top-level `code` member and also the `type` URI.
      it 'answers a per-verb GET the same gate as a problem document, uncacheable' do
        declare_query('menu') { render json: [] }
        status, headers, body = dispatch_verb(:show, 'menu', token_env('/kiosk/menu', agent_token))

        expect(status).to eq(402)
        expect(headers['WWW-Authenticate']).to eq('Kiosk-PoW realm="https://demo.example"')
        expect(headers['Content-Type']).to include('application/problem+json')
        # Spec §3.7.2: a single-use challenge is never cacheable, and
        # `no-store` is the one directive an operator cannot relax.
        expect(headers['Cache-Control']).to eq('no-store')
        expect(headers['Vary']).to eq('Authorization, Kiosk-PoW, Kiosk-Timezone')
        expect(body[:code]).to   eq('pow_required')
        expect(body[:type]).to   eq('https://kiosk.tech/problems/pow_required')
        expect(body[:status]).to eq(402)
        expect(body[:challenges]).to be_an(Array)
        expect(body[:challenges]).not_to be_empty
      end

      # §3.7.5, a MUST: the toll gate runs BEFORE the freshness check, because a
      # `304` is a served response. A `304 Not Modified` to an untolled
      # conditional request would give out an unmetered "your copy is current"
      # answer, which is the answer the toll charges for.
      #
      # The control is the second half: the same `If-None-Match: *` against
      # `GET <endpoint>/schema`, which is untolled by design, gets a `304`. So
      # the tolled plane refuses the conditional request on purpose.
      it 'answers 402 to a CONDITIONAL request — the toll runs before freshness' do
        declare_query('menu') { render json: [] }
        env = token_env('/kiosk/menu', agent_token,
                        'HTTP_IF_NONE_MATCH' => '*',
                        'HTTP_IF_MODIFIED_SINCE' => 'Sun, 06 Nov 2044 08:49:37 GMT')
        status, = dispatch_verb(:show, 'menu', env)

        expect(status).to eq(402)

        # The control: an untolled endpoint in the same process DOES honour it.
        sch_status, = described_class.action(:schema).call(
          Rack::MockRequest.env_for('/kiosk/schema', 'HTTP_IF_NONE_MATCH' => '*')
        )
        expect(sch_status).to eq(304)
      end
    end

    # ─── Payment-setup gate → WWW-Authenticate: Kiosk-Payment-Setup ────────
    describe 'the payment_setup_required 402' do
      before do
        # A provider that knows the principal has no card on file → the pay verb
        # raises PaymentSetupRequired BEFORE opening any DB transaction.
        provider = Object.new
        provider.define_singleton_method(:setup_required?) { |**| true }
        Kiosk.configure { |c| c.payment_provider = provider }

        # The pay verb only uses the leased connection after the setup check, so
        # a bare stub suffices. `.connection` is not defined: the engine must not
        # call it (it raises under permanent_connection_checkout = :disallowed).
        stub_const('ActiveRecord::Base', Class.new { define_singleton_method(:lease_connection) { Object.new } })
      end

      it 'carries WWW-Authenticate: Kiosk-Payment-Setup AND the body pointer' do
        status, headers, problem = dispatch(:pay, pay_env)
        expect(status).to eq(402)
        expect(headers['WWW-Authenticate']).to eq('Kiosk-Payment-Setup realm="https://demo.example"')
        expect(headers['Content-Type']).to include('application/problem+json')
        # The other 402 of the pair — same status, same endpoint, different
        # code — which is why the code member is the branch point.
        expect(problem[:code]).to   eq('payment_setup_required')
        expect(problem[:type]).to   eq('https://kiosk.tech/problems/payment_setup_required')
        expect(problem[:status]).to eq(402)
        expect(problem[:hint]).to include('payment_setup')
        expect(problem).not_to have_key(:challenges)
      end
    end

    # ─── payment_failed → NO WWW-Authenticate ──────────────────────────────
    #
    # §9: an operator MUST NOT emit a `WWW-Authenticate` header on
    # `payment_failed`. The other two 402s name a gate the client can act on
    # (solve a proof / set up a card); this one names none, so there is no
    # scheme to re-present credentials under. `www_authenticate_for` gives nil
    # for every other code, and this example holds that.
    describe 'the payment_failed 402' do
      before do
        # No database: the executor is stubbed to fail the way a PSP decline
        # reaches the render seam, which is the only part this example is about.
        ar_base = Class.new do
          define_singleton_method(:connection)       { Object.new }
          define_singleton_method(:lease_connection) { Object.new }
        end
        stub_const('ActiveRecord::Base', ar_base)
        executor = instance_double(Kiosk::Server::Executor)
        allow(executor).to receive(:call).and_raise(
          Kiosk::Server::Errors::PaymentFailed.new(
            'the card was declined', hint: 'the human may need to update the payment method'
          )
        )
        allow(Kiosk::Server::Executor).to receive(:new).and_return(executor)
      end

      it 'carries NO WWW-Authenticate header — no scheme names this gate (§9)' do
        declare_action('checkout')
        env = token_env('/kiosk/checkout', agent_token, method: 'POST',
                                                        input: '{}', 'CONTENT_TYPE' => 'application/json')
        status, headers, problem = dispatch_verb(:create, 'checkout', env)

        expect(status).to eq(402)
        expect(problem[:code]).to eq('payment_failed')
        # The two codes that have a scheme do get the header (asserted above),
        # so this absence is a decision of the render seam.
        expect(headers.to_h.transform_keys(&:downcase)).not_to have_key('www-authenticate')
      end
    end

    # ─── a 401 names the DPoP scheme, not a 402 gate ──────────────────────
    #
    # Dialed at `pay`: `GET /kiosk/schema` is public, resolves no identity and
    # cannot produce a 401. `pay` reaches `resolve_identity!`.
    it 'names the DPoP scheme on a 401, and no 402 gate (RFC 9449 §7.1)' do
      status, headers, = dispatch(:pay, token_env('/kiosk/pay', 'garbage', method: 'POST',
                                                                           input: '{}', 'CONTENT_TYPE' => 'application/json'))
      expect(status).to eq(401)
      expect(headers['WWW-Authenticate'])
        .to eq('DPoP algs="EdDSA", resource_metadata="https://demo.example/.well-known/oauth-protected-resource"')
    end
  end
end
