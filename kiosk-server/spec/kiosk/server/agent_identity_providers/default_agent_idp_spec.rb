# frozen_string_literal: true

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

  it "raises on a token signed by a different key" do
    other = Kiosk::Server::SigningKey.generate
    token = Kiosk::Server::JwtIssuer.issue(
      claims: { sub: "u", agent_id: "a", role: "customer", actor: "agent" },
      audience: "https://demo.example", signing_key: other,
    )
    expect { idp.verify(bearer(token)) }.to raise_error(Kiosk::Server::JwtIssuer::Error)
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
end

# A throwaway 2048-bit RSA public key in PEM form, generated once so the
# revocation specs can exercise agent_payment_key without minting a key per
# example.
SAMPLE_PEM = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
