# frozen_string_literal: true

require 'jwt'

module DefaultAgentIdpSpec
  # A throwaway Ed25519 public key in PEM form, generated once so the
  # revocation specs can exercise agent_payment_key without minting a key per
  # example.
  SAMPLE_PEM = OpenSSL::PKey.generate_key('ED25519').public_to_pem

  # The IdP reads the token alone; the proof is IdentityResolution's (spec Section 5.6).
  def presented(token) = { 'HTTP_AUTHORIZATION' => "DPoP #{token}" }

  # Decode a token this IdP minted, against the configured signing key, so an
  # assertion reads a claim off the ISSUED token rather than off a fixture.
  def decode(token)
    JWT.decode(
      token, Kiosk.configuration.signing_key.key, true, algorithms: ['EdDSA']
    ).first
  end

  def agent_token(agent_id:, **)
    Kiosk::Server::JwtIssuer.issue(
      claims: { sub: 'u', agent_id: agent_id, role: 'customer', actor: 'agent' },
      audience: 'https://demo.example', **
    )
  end
end

RSpec.shared_context 'with a DefaultAgentIdp on a configured origin' do
  include DefaultAgentIdpSpec

  subject(:idp) { described_class.new }

  before do
    Kiosk.reset!
    Kiosk.configure do |c|
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.issuer      = 'https://demo.example'
      c.roles       = %i[customer]
      c.revocation_store = MemoryRevocationStore.new
    end
  end
end

# An IdP whose agent lookup answers 'u-1' without a database.
RSpec.shared_context 'with an issuing DefaultAgentIdp' do
  include_context 'with a DefaultAgentIdp on a configured origin'

  let(:idp) do
    described_class.new.tap do |i|
      allow(i).to receive(:lookup_agent).and_return('user_id' => 'u-1', 'public_key' => DefaultAgentIdpSpec::SAMPLE_PEM)
    end
  end
end

# Records each agent lookup statement AND ITS BINDS via a minimal
# `ActiveRecord::Base.lease_connection` stub (AR is not loaded here). The stub
# offers no `quote`, so a lookup that reached for one would be a NoMethodError.
RSpec.shared_context 'with recorded DefaultAgentIdp lookups' do
  include_context 'with a DefaultAgentIdp on a configured origin'

  let(:recorder) { [] }

  before do
    log = recorder
    conn = Object.new
    conn.define_singleton_method(:exec_query) do |sql, _name = nil, binds = []|
      log << [sql, binds]
      [{ 'public_key' => DefaultAgentIdpSpec::SAMPLE_PEM, 'user_id' => 'u-1' }]
    end
    stub_const('ActiveRecord::Base', Class.new { define_singleton_method(:lease_connection) { conn } })
  end
end

RSpec.describe Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp do
  describe '#verify' do
    include_context 'with a DefaultAgentIdp on a configured origin'

    it 'verifies a self-issued agent token into an agent Identity' do
      token = Kiosk::Server::JwtIssuer.issue(
        claims: { sub: 'user-1', agent_id: 'agent-1', role: 'customer', actor: 'agent' },
        audience: 'https://demo.example'
      )
      identity = idp.verify(presented(token))
      expect(identity).to be_a(Kiosk::Identity)
      expect(identity.user_id).to  eq('user-1')
      expect(identity.agent_id).to eq('agent-1')
      expect(identity.role).to     eq('customer')
      expect(identity.actor).to eq('agent')
    end

    it 'returns nil when there is no Authorization header' do
      expect(idp.verify({})).to be_nil
    end

    it 'returns nil for a valid token sent as a Bearer token: the scheme is DPoP' do
      token = agent_token(agent_id: 'agent-1')
      expect(idp.verify('HTTP_AUTHORIZATION' => "Bearer #{token}")).to be_nil
    end

    # Operator key rotation (spec Section 4.4): the previous key still verifies.
    it 'verifies a token that the previous signing key signed' do
      previous = Kiosk.configuration.signing_key
      Kiosk.configure do |c|
        c.signing_key          = Kiosk::Server::SigningKey.generate
        c.previous_signing_key = Kiosk::Server::SigningKey.from_pem(previous.key.public_to_pem)
      end
      expect(idp.verify(presented(agent_token(agent_id: 'agent-1', signing_key: previous)))).to be_a(Kiosk::Identity)
    end

    it 'returns nil for a token that neither the current nor the previous key signed' do
      Kiosk.configure { |c| c.previous_signing_key = Kiosk::Server::SigningKey.generate }
      token = agent_token(agent_id: 'a', signing_key: Kiosk::Server::SigningKey.generate)
      expect(idp.verify(presented(token))).to be_nil
    end

    # Verification failures resolve to nil (→ 401 at the controller), never escape
    # as JwtIssuer::Error (which would surface as HTTP 500).
    it 'returns nil for a token signed by a different key' do
      token = agent_token(agent_id: 'a', signing_key: Kiosk::Server::SigningKey.generate)
      expect(idp.verify(presented(token))).to be_nil
    end

    it 'returns nil for an expired token' do
      # default 1h lifetime + 60s leeway long gone
      token = agent_token(agent_id: 'a', now: Time.current - 7200)
      expect(idp.verify(presented(token))).to be_nil
    end

    it 'returns nil for a malformed (garbage) token' do
      expect(idp.verify(presented('definitely-not-a-jwt'))).to be_nil
    end

    it 'returns nil for a revoked token' do
      token = agent_token(agent_id: 'agent-rev', now: Time.current - 10)
      Kiosk.configuration.revocation_store.revoke_all('agent-rev', at: Time.now.to_i)
      expect(idp.verify(presented(token))).to be_nil
    end
  end

  # A revoked agent must not be able to authenticate or sign mandates, so both
  # agent lookups scope to `revoked_at IS NULL`, with the id as a bind.
  describe 'honors agent revocation' do
    include_context 'with recorded DefaultAgentIdp lookups'

    it 'scopes agent_payment_key lookups to non-revoked agents' do
      idp.agent_payment_key('agent-1')
      sql, binds = recorder.last
      expect(sql).to include('FROM kiosk.agents WHERE id = $1 AND revoked_at IS NULL')
      expect(binds).to eq(['agent-1'])
    end

    it 'scopes lookup_agent lookups to non-revoked agents' do
      idp.send(:lookup_agent, 'agent-1')
      sql, binds = recorder.last
      expect(sql).to include('FROM kiosk.agents WHERE id = $1 AND revoked_at IS NULL')
      expect(binds).to eq(['agent-1'])
    end

    # The column is the only interpolated part, and it is one of four literals
    # in the file rather than anything a caller can reach — Postgres cannot
    # bind an identifier in any case.
    it 'selects only the columns its caller asked for' do
      idp.send(:lookup_agent, 'agent-1')
      expect(recorder.last.first).to start_with('SELECT user_id, public_key FROM')
      idp.agent_payment_key('agent-1')
      expect(recorder.last.first).to start_with('SELECT public_key FROM')
    end
  end

  describe '#issue (role-less path)' do
    include_context 'with an issuing DefaultAgentIdp'

    it 'omits the role claim entirely when role is nil' do
      payload = decode(idp.issue(agent_id: 'a-1', role: nil))

      expect(payload).not_to have_key('role')
      expect(payload['sub']).to eq('u-1')
      expect(payload['agent_id']).to eq('a-1')
    end

    it 'still carries the role claim when a role is present' do
      payload = decode(idp.issue(agent_id: 'a-1', role: :customer))
      expect(payload['role']).to eq('customer')
    end

    it 'round-trips to a usable role-less Identity (the regression: an empty-string role claim made Identity raise)' do
      token  = idp.issue(agent_id: 'a-1', role: nil)
      claims = Kiosk::Server::JwtIssuer.verify(
        token: token,
        jwks: Kiosk::Server::Jwks.build(keys: [Kiosk.configuration.signing_key]),
        audience: 'https://demo.example',
        issuer: 'https://demo.example'
      )

      # The exact construction #verify performs — must not raise for nil role.
      identity = Kiosk::Identity.new(
        user_id: claims[:sub], role: claims[:role], actor: 'agent',
        agent_id: claims[:agent_id], claims: claims
      )
      expect(identity.role).to be_nil
      expect(identity.agent_id).to eq('a-1')
    end
  end

  # ── SPEC-043's `actor` claim, read off a token this IdP actually minted ─────
  #
  # A fixture written into a hand-built token, or a `Kiosk::Identity`
  # constructor argument, proves the test's setup and not the issuer's output.
  # So this decodes what `#issue` produced and reads the claim off the payload.
  describe '#issue — the claims every minted token carries' do
    include_context 'with an issuing DefaultAgentIdp'

    # RFC 9449 Section 6.1: the token is bound to the key the agent registered.
    it 'binds every token it mints to the agent key, as `cnf.jkt`' do
      jkt = Kiosk::Server::SigningKey.from_pem(DefaultAgentIdpSpec::SAMPLE_PEM).kid
      expect(decode(idp.issue(agent_id: 'a-1', role: nil))['cnf']).to eq('jkt' => jkt)
    end

    it 'stamps an `actor` claim of `agent` on every token it mints, role or no role' do
      with_role    = decode(idp.issue(agent_id: 'a-1', role: :customer))
      without_role = decode(idp.issue(agent_id: 'a-1', role: nil))

      expect(with_role['actor']).to    eq('agent')
      expect(without_role['actor']).to eq('agent')
    end

    # The claim survives the round trip the protocol actually performs — a token
    # whose `actor` were dropped or rewritten between issue and verify would
    # still satisfy the assertion above.
    it 'carries the `actor` claim through verification into the resolved Identity' do
      identity = idp.verify(presented(idp.issue(agent_id: 'a-1', role: :customer)))

      expect(identity.claims[:actor]).to eq('agent')
      expect(identity.actor).to eq('agent')
    end
  end

  # ── SPEC-045: two live tokens for ONE identity, both accepted ───────────────
  #
  # One assistant may hold a session on two devices without either killing the
  # other. The revocation watermark moves only on a key rotation and on the
  # binding ceremony's rebind and unlink, never on issuance — `#issue` only
  # READS it (`mint_instant`) so it cannot mint into an already-revoked window.
  describe '#issue — concurrent tokens for one identity' do
    include_context 'with an issuing DefaultAgentIdp'

    it 'keeps an earlier token valid after a second is minted for the same agent' do
      first  = idp.issue(agent_id: 'a-1', role: :customer)
      second = idp.issue(agent_id: 'a-1', role: :customer)

      # Two DISTINCT tokens: they are minted in the same second, so `jti` is
      # what separates them, and it is checked.
      expect(second).not_to eq(first)
      expect(decode(first)['jti']).not_to eq(decode(second)['jti'])

      [first, second].each do |token|
        identity = idp.verify(presented(token))
        expect(identity).to          be_a(Kiosk::Identity)
        expect(identity.agent_id).to eq('a-1')
        expect(identity.user_id).to  eq('u-1')
      end
    end

    # One watermark ahead of both tokens kills BOTH, so
    # "concurrent" is a property of the session and not a hole in revocation.
    it "revokes both at once when the agent's watermark passes them" do
      first  = idp.issue(agent_id: 'a-1', role: :customer)
      second = idp.issue(agent_id: 'a-1', role: :customer)
      Kiosk.configuration.revocation_store.revoke_all('a-1', at: Time.now.to_i + 120)

      expect(idp.verify(presented(first))).to  be_nil
      expect(idp.verify(presented(second))).to be_nil
    end
  end

  # Spec Section 10: an access token lives one hour unless the operator
  # configures another lifetime. Read off the token `#issue` mints.
  describe '#issue — the lifetime of the token it mints' do
    include_context 'with an issuing DefaultAgentIdp'

    def lifetime = decode(idp.issue(agent_id: 'a-1', role: :customer)).values_at('exp', 'iat').reduce(:-)

    it 'mints a token that lives one hour by default' do
      expect(lifetime).to eq(3600)
    end

    it 'mints a token that lives access_token_ttl seconds when the operator configures it' do
      Kiosk.configure { |c| c.access_token_ttl = 900 }
      expect(lifetime).to eq(900)
    end
  end
end
