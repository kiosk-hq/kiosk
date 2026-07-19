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
  # Both agent lookups must scope to `revoked_at IS NULL`. We record the SQL
  # via a minimal ActiveRecord::Base.connection stub (AR isn't loaded here).
  describe "honors agent revocation" do
    let(:recorder) { [] }
    let(:fake_conn) do
      sql_log = recorder
      Object.new.tap do |conn|
        conn.define_singleton_method(:execute) do |sql|
          sql_log << sql
          [{ "public_key" => SAMPLE_PEM, "user_id" => "u-1" }]
        end
        conn.define_singleton_method(:quote) { |v| "'#{v}'" }
      end
    end

    before do
      conn = fake_conn
      ar_base = Class.new do
        define_singleton_method(:connection) { conn }
      end
      stub_const("ActiveRecord::Base", ar_base)
    end

    it "scopes agent_payment_key lookups to non-revoked agents" do
      idp.agent_payment_key("agent-1")
      expect(recorder.last).to match(/FROM kiosk\.agents WHERE id = 'agent-1' AND revoked_at IS NULL/)
    end

    it "scopes lookup_user_id lookups to non-revoked agents" do
      idp.send(:lookup_user_id, "agent-1")
      expect(recorder.last).to match(/FROM kiosk\.agents WHERE id = 'agent-1' AND revoked_at IS NULL/)
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
end

# A throwaway 2048-bit RSA public key in PEM form, generated once so the
# revocation specs can exercise agent_payment_key without minting a key per
# example.
SAMPLE_PEM = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
