# frozen_string_literal: true

# PoW-SHAPE validation of the `Kiosk-PoW` request header.
#
# When `config.validate_requests` is true — which is its default — the proof(s)
# parsed from the `Kiosk-PoW` request header are validated against the vendored
# normative PoW schema BEFORE PowGate.gate consumes them. Without this check a
# `{solutions:[…]}` shape (not the schema shape `{challenge:,nonce:}`) gives
# PowGate.extract_proofs an empty list, and the gate re-issues a fresh 402 on
# every retry with no diagnostic. This layer turns that silent re-challenge
# into a clear 400 hint.
#
# `validate_requests` is the PROOF-shape flag and only that: a verb's own
# ARGUMENTS are validated against its `input_schema` unconditionally on the
# per-verb wire, flag or no flag. The verb dialled here declares the open
# object, so nothing in this file is answered by the argument layer.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host. Every answer asserted below is an RFC 9457 problem
# document: the branch point is the TOP-LEVEL `code`, served as
# `application/problem+json`.

require 'rack/mock'
require 'json'
require 'kiosk/pow'
require 'kiosk/reputation'

module WireControllerValidationSpec
  # Challenges every verb, so a request that clears validation reaches the
  # gate (402 pow_required) rather than Executor.
  class AlwaysChallengePolicy < Kiosk::Reputation::Policy
    def challenge_for(**) = { alg: 'argon2id', params: Kiosk::Pow.params(d: 4, m: 8) }
  end

  def dispatch_verb(name, env)
    env['action_dispatch.request.path_parameters'] =
      { controller: 'kiosk/server/verb', action: 'show', kiosk_verb: name }
    status, headers, body = Kiosk::Server::VerbController.action(:show).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  def bearer_env(path, token, **)
    Rack::MockRequest.env_for(path, 'HTTP_AUTHORIZATION' => "Bearer #{token}", **)
  end

  def agent_token
    @agent_token ||= Kiosk::Server::JwtIssuer.issue(
      claims: { sub: 'u-1', agent_id: 'a-1', role: 'customer', actor: 'agent' },
      audience: 'https://demo.example'
    )
  end

  # Dial `GET /kiosk/catalog` carrying the proof in the `Kiosk-PoW` header (as
  # raw JSON — the header is the wire location per ADR-0022, and on a GET it is
  # the ONLY location there is). An always-challenge reputation policy is
  # configured (see the shared context), so a request that CLEARS validation
  # reaches PowGate.gate and comes back 402 pow_required — never touching
  # Executor / ActiveRecord. That lets us assert cleanly on the validation
  # OUTCOME: a malformed proof is a 400 (rejected before the gate), a
  # valid/absent proof is a 402 (validation passed it through to the gate).
  #
  # `header` may be a Hash (a single proof, serialised to JSON), an Array of
  # proofs (serialised to a JSON array), a raw String header value, or :absent.
  def call_with_pow(header)
    opts = { method: 'GET' }
    unless header == :absent
      opts['HTTP_KIOSK_POW'] = header.is_a?(String) ? header : JSON.generate(header)
    end
    dispatch_verb('catalog', bearer_env('/kiosk/catalog', agent_token, **opts))
  end

  def validate_any_proof! = Kiosk::Server::RequestValidation.validate_proofs!([{ challenge: {}, nonce: {} }])

  # A structurally VALID challenge object (all schema-required fields present).
  def valid_challenge
    {
      id: 'chal-1',
      alg: 'equihash',
      params: { n: 168, k: 7 },
      salt: 'c2FsdA==',
      exp: Time.now.to_i + 300,
      sig: 'deadbeef'
    }
  end
end

RSpec.shared_context 'wire controller validation spec: gated origin' do
  include WireControllerValidationSpec

  before do
    Kiosk::Reputation::Backends.register('argon2id', Kiosk::Pow)
    Kiosk.configure do |c|
      c.signing_key       = Kiosk::Server::SigningKey.generate
      c.issuer            = 'https://demo.example'
      c.roles             = %i[customer]
      c.agent_idp         = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
      c.reputation_policy = WireControllerValidationSpec::AlwaysChallengePolicy.new
      c.pow_secret        = 'test-pow-secret-of-at-least-32-bytes'
    end
    Kiosk::Server::RequestValidation.reset!

    # The verb dialled by every example. Its `input_schema` is the OPEN object,
    # so the unconditional ARGUMENT validation never fires and each 400 below is
    # unambiguously the PROOF-shape check.
    declare_query('catalog') { render json: [] }
  end

  after do
    Kiosk::Server::RequestValidation.reset!
    Kiosk::Reputation::Backends.reset!
  end
end

RSpec.shared_context 'wire controller validation spec: shape check on' do
  before { Kiosk.configure { |c| c.validate_requests = true } }
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  context 'with validate_requests: true' do
    include_context 'wire controller validation spec: shape check on'

    it 'rejects the K-479 shape ({solutions:[…]}) with 400 bad_request + hint (NOT a 402)' do
      status, headers, problem = call_with_pow(solutions: [{ indices: [1, 2, 3], header_nonce: 0 }])

      expect(status).to eq(400)
      expect(headers['Content-Type']).to include('application/problem+json')
      expect(problem[:code]).to   eq('bad_request')
      expect(problem[:type]).to   eq('https://kiosk.tech/problems/bad_request')
      expect(problem[:status]).to eq(400)
      expect(problem[:hint]).to include('challenge')
      expect(problem[:hint]).to include('nonce')
      # It must NOT have been turned into a fresh pow_required challenge.
      expect(problem[:code]).not_to eq('pow_required')
      expect(problem).not_to have_key(:challenges)
    end

    it 'rejects a proof missing the echoed challenge with 400 bad_request' do
      status, headers, problem = call_with_pow(nonce: { indices: [1, 2, 3] })

      expect(status).to eq(400)
      expect(headers['Content-Type']).to include('application/problem+json')
      expect(problem[:code]).to eq('bad_request')
      expect(problem[:hint]).to include('challenge')
    end
  end
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  context 'with validate_requests: true' do
    include_context 'wire controller validation spec: shape check on'

    it 'rejects a malformed proof inside a JSON-array header (per-proof validation)' do
      status, _headers, problem = call_with_pow(
        [{ challenge: valid_challenge, nonce: { indices: [1, 2, 3, 4] } },
         { solutions: [{ indices: [9] }] }]
      )

      expect(status).to eq(400)
      expect(problem[:code]).to eq('bad_request')
    end

    it 'does NOT reject a well-formed proof at the validation step (it passes to the gate)' do
      # A well-formed-but-forged proof clears the SHAPE check and reaches the
      # gate, which does the real cryptographic verification — the forged proof
      # fails there and the gate re-issues a fresh 402. The point: validation
      # did NOT reject it with a 400; the gate (not the shape check) is still the
      # authority on whether a proof is valid.
      status, _headers, problem = call_with_pow(
        challenge: valid_challenge, nonce: { indices: [1, 2, 3, 4] }
      )

      expect(status).to eq(402)
      expect(problem[:code]).to eq('pow_required')
      expect(problem[:code]).not_to eq('bad_request')
      expect(problem[:challenges]).to be_an(Array)
    end
  end
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  context 'with validate_requests: true' do
    include_context 'wire controller validation spec: shape check on'

    it 'accepts a JSON-array of well-formed proofs (passes to the gate)' do
      status, _headers, problem = call_with_pow(
        [{ challenge: valid_challenge, nonce: { indices: [1, 2, 3, 4] } }]
      )

      expect(status).to eq(402)
      expect(problem[:code]).to eq('pow_required')
      expect(problem[:code]).not_to eq('bad_request')
    end

    # `indices` items are u64. `pack("Q<")` truncates mod 2**64, so an
    # out-of-range index is a different spelling of an in-range leaf. It is
    # refused as a malformed proof, 400, before the gate.
    it 'rejects an index at 2**64 with 400 bad_request (u64 upper bound)' do
      status, _headers, problem = call_with_pow(
        challenge: valid_challenge, nonce: { indices: [1, 2, 3, 1 << 64] }
      )

      expect(status).to eq(400)
      expect(problem[:code]).to eq('bad_request')
      expect(problem[:code]).not_to eq('pow_required')
    end
  end
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  context 'with validate_requests: true' do
    include_context 'wire controller validation spec: shape check on'

    # The bound must not refuse the largest legal index. The schema writes the
    # upper bound as an inclusive `maximum: 2**64 - 1`, so a double-precision
    # validator cannot round this value onto an excluded bound. Ruby's JSON
    # parser is exact, so this pins the accepted set: 2**64 - 1 is in it.
    it 'accepts an index at 2**64 - 1 — the largest legal u64 (passes to the gate)' do
      status, _headers, problem = call_with_pow(
        challenge: valid_challenge, nonce: { indices: [1, 2, 3, (1 << 64) - 1] }
      )

      expect(status).to eq(402)
      expect(problem[:code]).to eq('pow_required')
      expect(problem[:code]).not_to eq('bad_request')
    end

    it 'rejects a negative index with 400 bad_request (u64 lower bound)' do
      status, _headers, problem = call_with_pow(
        challenge: valid_challenge, nonce: { indices: [1, 2, 3, -1] }
      )

      expect(status).to eq(400)
      expect(problem[:code]).to eq('bad_request')
      expect(problem[:code]).not_to eq('pow_required')
    end
  end
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  context 'with validate_requests: true' do
    include_context 'wire controller validation spec: shape check on'

    # `header_nonce` is a u32, folded into the seed with `pack("V")`, which
    # truncates mod 2**32. Out-of-range values are refused here as malformed
    # proofs, before the gate.
    it 'rejects a header_nonce at 2**32 with 400 bad_request (u32 upper bound)' do
      status, _headers, problem = call_with_pow(
        challenge: valid_challenge, nonce: { indices: [1, 2, 3, 4], header_nonce: 1 << 32 }
      )

      expect(status).to eq(400)
      expect(problem[:code]).to eq('bad_request')
      expect(problem[:code]).not_to eq('pow_required')
    end

    it 'accepts a header_nonce at 2**32 - 1 — the largest legal u32 (passes to the gate)' do
      status, _headers, problem = call_with_pow(
        challenge: valid_challenge, nonce: { indices: [1, 2, 3, 4], header_nonce: (1 << 32) - 1 }
      )

      expect(status).to eq(402)
      expect(problem[:code]).to eq('pow_required')
      expect(problem[:code]).not_to eq('bad_request')
    end
  end
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  context 'with validate_requests: true' do
    include_context 'wire controller validation spec: shape check on'

    it 'rejects a negative header_nonce with 400 bad_request (u32 lower bound)' do
      status, _headers, problem = call_with_pow(
        challenge: valid_challenge, nonce: { indices: [1, 2, 3, 4], header_nonce: -1 }
      )

      expect(status).to eq(400)
      expect(problem[:code]).to eq('bad_request')
      expect(problem[:code]).not_to eq('pow_required')
    end

    it "answers a proof for an algorithm it does not implement with a challenge for one it does, never a 400 on the nonce's shape" do
      proof = { challenge: valid_challenge.merge(alg: 'cuckoo', params: { edge_bits: 29 }),
                nonce: 'a-shape-only-cuckoo-defines' }
      status, _headers, body = call_with_pow(proof)
      expect(status).to eq(402)
      expect(body[:code]).to eq('pow_required')
      expect(body[:challenges].map { |c| c[:alg] }).to eq(['argon2id'])
    end
  end
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  context 'with validate_requests: true' do
    include_context 'wire controller validation spec: shape check on'

    it 'leaves an ABSENT header untouched — the normal 402 challenge path runs (no 400)' do
      # An absent header means the initial request; the gate must still issue the
      # normal pow_required 402. Missing proof is NOT a malformed proof — it must
      # never become a 400.
      status, _headers, problem = call_with_pow(:absent)

      expect(status).to eq(402)
      expect(problem[:code]).to eq('pow_required')
      expect(problem[:code]).not_to eq('bad_request')
      expect(problem[:challenges]).not_to be_empty
    end

    it 'rejects a malformed Kiosk-PoW header (invalid JSON) with 400 + hint' do
      status, headers, problem = call_with_pow('{not json')

      expect(status).to eq(400)
      expect(headers['Content-Type']).to include('application/problem+json')
      expect(problem[:code]).to eq('bad_request')
      expect(problem[:hint]).to include('Kiosk-PoW')
    end
  end
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  context 'with validate_requests explicitly off' do
    before { Kiosk.configure { |c| c.validate_requests = false } }

    it 'does NOT raise a validation error on a malformed proof (byte-identical to today)' do
      # With the flag off, extract_proofs ignores the malformed proof ([] proofs)
      # and the gate re-issues a fresh 402. No 400 bad_request comes from a
      # validation step that is not running.
      status, _headers, problem = call_with_pow(solutions: [{ indices: [1, 2, 3] }])

      expect(status).to eq(402)
      expect(problem[:code]).to eq('pow_required')
      expect(problem[:code]).not_to eq('bad_request')
    end

    it 'STILL rejects a syntactically-invalid header JSON with 400 (parse is not gated by the flag)' do
      # Header-JSON parsing happens before the opt-in shape check; a header that
      # is not valid JSON at all is a malformed request regardless of the flag.
      status, _headers, problem = call_with_pow('{not json')

      expect(status).to eq(400)
      expect(problem[:code]).to eq('bad_request')
    end
  end
end

RSpec.describe 'Opt-in PoW-shape request validation (slice-1, K-479)' do
  include_context 'wire controller validation spec: gated origin'

  # ── Fail-loud when the RUNTIME dependency is not loadable ──────────────────
  context 'when validate_requests is on but json_schemer is not loadable' do
    before do
      Kiosk.configure { |c| c.validate_requests = true }
      Kiosk::Server::RequestValidation.reset!
      allow(Kiosk::Server::RequestValidation).to receive(:require)
        .with('json_schemer').and_raise(LoadError)
    end

    it 'raises a ConfigurationError naming the gem' do
      expect { validate_any_proof! }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError, /json_schemer/)
    end

    # The message must agree with the gemspec, which declares json_schemer a
    # runtime dependency.
    it 'does not call the gem optional, because the gemspec declares it a runtime dependency' do
      spec = Gem::Specification.load(
        File.expand_path('../../../kiosk-server.gemspec', __dir__)
      )
      expect(spec.runtime_dependencies.map(&:name)).to include('json_schemer')

      expect { validate_any_proof! }.to raise_error(Kiosk::Server::Errors::ConfigurationError) { |e|
        expect(e.message).not_to match(/optional/i)
        expect(e.message).to match(/RUNTIME dependency/)
      }
    end
  end
end
