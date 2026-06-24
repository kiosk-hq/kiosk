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
end
