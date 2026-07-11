# frozen_string_literal: true

require "jwt"

RSpec.describe Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp do
  before(:all) { @rsa = OpenSSL::PKey::RSA.generate(2048) }

  let(:key)    { Kiosk::Server::SigningKey.new(@rsa) }
  let(:issuer) { "https://combette.example/kiosk" }

  before do
    Kiosk.configure do |c|
      c.issuer      = issuer
      c.signing_key = key
    end
  end

  describe "#issue (role-less path, ADR-0011 / K-078)" do
    let(:idp) do
      described_class.new.tap { |i| allow(i).to receive(:lookup_user_id).and_return("u-1") }
    end

    it "omits the role claim entirely when role is nil" do
      token = idp.issue(agent_id: "a-1", role: nil)
      payload, = ::JWT.decode(token, key.rsa.public_key, true, algorithms: ["RS256"])

      expect(payload).not_to have_key("role")
      expect(payload["sub"]).to eq("u-1")
      expect(payload["agent_id"]).to eq("a-1")
    end

    it "round-trips to a usable role-less Identity (the K-078 regression: an empty-string role claim made Identity raise)" do
      token  = idp.issue(agent_id: "a-1", role: nil)
      claims = Kiosk::Server::JwtIssuer.verify(
        token:    token,
        jwks:     Kiosk::Server::Jwks.build(keys: [key]),
        audience: issuer,
        issuer:   issuer,
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
      payload, = ::JWT.decode(token, key.rsa.public_key, true, algorithms: ["RS256"])
      expect(payload["role"]).to eq("customer")
    end
  end
end
