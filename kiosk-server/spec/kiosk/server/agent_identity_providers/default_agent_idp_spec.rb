# frozen_string_literal: true

require "jwt"

RSpec.describe Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp do
  subject(:idp) { described_class.new }

  before do
    Kiosk.reset!
    Kiosk.configure do |c|
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.issuer      = "https://demo.example"
      c.roles       = %i[customer]
    end
  end

  def bearer(token) = { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

  # Decode a token this IdP minted, against the configured signing key. The
  # point of every assertion that uses it is to read a claim off the ISSUED
  # token rather than off a fixture the example wrote itself (K-1160).
  def decode(token)
    ::JWT.decode(
      token, Kiosk.configuration.signing_key.rsa.public_key, true, algorithms: ["RS256"],
    ).first
  end

  it "verifies a self-issued agent token into an agent Identity" do
    token = Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "user-1", agent_id: "agent-1", role: "customer", actor: "agent" },
      audience: "https://demo.example",
    )
    identity = idp.verify(bearer(token))
    expect(identity).to be_a(Kiosk::Identity)
    expect(identity.user_id).to  eq("user-1")
    expect(identity.agent_id).to eq("agent-1")
    expect(identity.role).to     eq("customer")
    expect(identity).to be_agent
  end

  it "returns nil when there is no Authorization header" do
    expect(idp.verify({})).to be_nil
  end

  # Verification failures resolve to nil (→ 401 at the controller),
  # never escape as JwtIssuer::Error (which surfaced as HTTP 500).
  it "returns nil for a token signed by a different key" do
    other = Kiosk::Server::SigningKey.generate
    token = Kiosk::Server::JwtIssuer.issue(
      claims: { sub: "u", agent_id: "a", role: "customer", actor: "agent" },
      audience: "https://demo.example", signing_key: other,
    )
    expect(idp.verify(bearer(token))).to be_nil
  end

  it "returns nil for an expired token" do
    token = Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u", agent_id: "a", role: "customer", actor: "agent" },
      audience: "https://demo.example",
      now:      Time.now - 7200, # default 1h lifetime + 60s leeway long gone
    )
    expect(idp.verify(bearer(token))).to be_nil
  end

  it "returns nil for a malformed (garbage) token" do
    expect(idp.verify(bearer("definitely-not-a-jwt"))).to be_nil
  end

  it "returns nil for a revoked token" do
    token = Kiosk::Server::JwtIssuer.issue(
      claims:   { sub: "u", agent_id: "agent-rev", role: "customer", actor: "agent" },
      audience: "https://demo.example",
      now:      Time.now - 10,
    )
    Kiosk.configuration.revocation_store.revoke_all("agent-rev", at: Time.now.to_i)
    expect(idp.verify(bearer(token))).to be_nil
  end

  # I1 — a revoked agent must not be able to authenticate or sign mandates.
  # Both agent lookups must scope to `revoked_at IS NULL`. We record the
  # statement AND ITS BINDS via a minimal `ActiveRecord::Base.lease_connection`
  # stub (AR isn't loaded here). The stub offers no `quote`, so a lookup that
  # reached for one would be a NoMethodError — K-782 replaced all four with one
  # bind-parameterised statement.
  describe "honors agent revocation" do
    let(:recorder) { [] }
    let(:fake_conn) do
      log = recorder
      Object.new.tap do |conn|
        conn.define_singleton_method(:exec_query) do |sql, _name = nil, binds = []|
          log << [sql, binds]
          [{ "public_key" => SAMPLE_PEM, "user_id" => "u-1" }]
        end
      end
    end

    before do
      conn = fake_conn
      ar_base = Class.new do
        define_singleton_method(:lease_connection) { conn }
      end
      stub_const("ActiveRecord::Base", ar_base)
    end

    it "scopes agent_payment_key lookups to non-revoked agents" do
      idp.agent_payment_key("agent-1")
      sql, binds = recorder.last
      expect(sql).to match(/FROM kiosk\.agents WHERE id = \$1 AND revoked_at IS NULL/)
      expect(binds).to eq(["agent-1"])
    end

    it "scopes lookup_user_id lookups to non-revoked agents" do
      idp.send(:lookup_user_id, "agent-1")
      sql, binds = recorder.last
      expect(sql).to match(/FROM kiosk\.agents WHERE id = \$1 AND revoked_at IS NULL/)
      expect(binds).to eq(["agent-1"])
    end

    # The COLUMN is the only thing still interpolated, and it is one of four
    # literals in the file rather than anything a caller can reach — Postgres
    # cannot bind an identifier in any case.
    it "selects only the column its caller asked for" do
      idp.send(:lookup_user_id, "agent-1")
      expect(recorder.last.first).to start_with("SELECT user_id FROM")
      idp.agent_payment_key("agent-1")
      expect(recorder.last.first).to start_with("SELECT public_key FROM")
    end
  end
  describe "#issue (role-less path)" do
    let(:idp) do
      described_class.new.tap { |i| allow(i).to receive(:lookup_user_id).and_return("u-1") }
    end

    it "omits the role claim entirely when role is nil" do
      token = idp.issue(agent_id: "a-1", role: nil)
      payload, = ::JWT.decode(token, Kiosk.configuration.signing_key.rsa.public_key, true, algorithms: ["RS256"])

      expect(payload).not_to have_key("role")
      expect(payload["sub"]).to eq("u-1")
      expect(payload["agent_id"]).to eq("a-1")
    end

    it "round-trips to a usable role-less Identity (the regression: an empty-string role claim made Identity raise)" do
      token  = idp.issue(agent_id: "a-1", role: nil)
      claims = Kiosk::Server::JwtIssuer.verify(
        token:    token,
        jwks:     Kiosk::Server::Jwks.build(keys: [Kiosk.configuration.signing_key]),
        audience: "https://demo.example",
        issuer:   "https://demo.example",
      )

      # The exact construction #verify performs — must not raise for nil role.
      identity = Kiosk::Identity.new(
        user_id: claims[:sub], role: claims[:role], actor: "agent",
        agent_id: claims[:agent_id], claims: claims,
      )
      expect(identity.role).to be_nil
      expect(identity.agent_id).to eq("a-1")
    end

    it "still carries the role claim when a role is present" do
      token = idp.issue(agent_id: "a-1", role: :customer)
      payload, = ::JWT.decode(token, Kiosk.configuration.signing_key.rsa.public_key, true, algorithms: ["RS256"])
      expect(payload["role"]).to eq("customer")
    end
  end

  # ── SPEC-043's `actor` claim, read off a token this IdP actually minted ─────
  #
  # K-1160: the matrix listed `actor: "agent"` among the access token's claims
  # and nothing asserted it. Every `actor: "agent"` in the spec tree was either a
  # fixture the spec itself wrote into a hand-built token or a `Kiosk::Identity`
  # constructor argument — both prove the TEST's setup, not the issuer's output.
  # So this decodes what `#issue` produced and reads the claim off the payload.
  describe "#issue — the claims every minted token carries" do
    let(:idp) do
      described_class.new.tap { |i| allow(i).to receive(:lookup_user_id).and_return("u-1") }
    end

    it "stamps an `actor` claim of `agent` on every token it mints, role or no role" do
      with_role    = decode(idp.issue(agent_id: "a-1", role: :customer))
      without_role = decode(idp.issue(agent_id: "a-1", role: nil))

      expect(with_role["actor"]).to    eq("agent")
      expect(without_role["actor"]).to eq("agent")
    end

    # The claim survives the round trip the wire actually performs — a token
    # whose `actor` were dropped or rewritten between issue and verify would
    # still satisfy the assertion above.
    it "carries the `actor` claim through verification into the resolved Identity" do
      identity = idp.verify(bearer(idp.issue(agent_id: "a-1", role: :customer)))

      expect(identity.claims[:actor]).to eq("agent")
      expect(identity.actor).to         eq("agent")
    end
  end

  # ── SPEC-045: two live tokens for ONE identity, both accepted (K-1162) ──────
  #
  # «Multiple concurrent tokens for one identity remain valid» was asserted by
  # nothing: SPEC-045's four anchors cover the one-hour default, the `expires_in`
  # override, rejection after expiry and acceptance at/after the revocation
  # watermark, and not one of them mints a SECOND token. The clause is what lets
  # one assistant hold a session on two devices without either killing the other.
  #
  # It is true of this engine by construction: the revocation watermark is
  # advanced ONLY by `/auth/revoke` and by the binding ceremony's link/unlink/
  # rebind, never by issuance — `#issue` merely READS it (`mint_instant`) so it
  # cannot mint into an already-revoked window. Nothing about minting a token
  # invalidates an earlier one. This asserts that rather than assuming it.
  describe "#issue — concurrent tokens for one identity" do
    let(:idp) do
      described_class.new.tap { |i| allow(i).to receive(:lookup_user_id).and_return("u-1") }
    end

    it "keeps an earlier token valid after a second is minted for the same agent" do
      first  = idp.issue(agent_id: "a-1", role: :customer)
      second = idp.issue(agent_id: "a-1", role: :customer)

      # Two DISTINCT tokens, or "both are accepted" is one acceptance asserted
      # twice — they are minted in the same second, so `jti` is what separates
      # them and it is checked rather than assumed.
      expect(second).not_to eq(first)
      expect(decode(first)["jti"]).not_to eq(decode(second)["jti"])

      [first, second].each do |token|
        identity = idp.verify(bearer(token))
        expect(identity).to          be_a(Kiosk::Identity)
        expect(identity.agent_id).to eq("a-1")
        expect(identity.user_id).to  eq("u-1")
      end
    end

    # …and the pair is genuinely revocable together: one `/auth/revoke` at a
    # watermark ahead of both kills BOTH, which is what makes "concurrent" a
    # property of the session and not a hole in revocation.
    it "revokes both at once when the agent's watermark passes them" do
      first  = idp.issue(agent_id: "a-1", role: :customer)
      second = idp.issue(agent_id: "a-1", role: :customer)
      Kiosk.configuration.revocation_store.revoke_all("a-1", at: Time.now.to_i + 120)

      expect(idp.verify(bearer(first))).to  be_nil
      expect(idp.verify(bearer(second))).to be_nil
    end
  end
end

# A throwaway 2048-bit RSA public key in PEM form, generated once so the
# revocation specs can exercise agent_payment_key without minting a key per
# example.
SAMPLE_PEM = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
