# frozen_string_literal: true

RSpec.describe Kiosk::Server::IdentityResolution do
  let(:agent_identity) { build_identity(actor: "agent") }
  let(:human_identity) { build_identity(actor: "human", agent_id: nil) }

  def fixed_idp(identity) = Class.new { define_method(:verify) { |_r| identity } }.new
  def nil_idp             = Class.new { define_method(:verify) { |_r| nil } }.new

  describe ".agent_idp" do
    it "defaults to the bundled kiosk-pop DefaultAgentIdp" do
      expect(described_class.agent_idp)
        .to be_a(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
    end

    # T-104. The demos used to override this with a hand-copied composite whose
    # second arm parsed a self-asserted `agent:u-…:a-…:r-…` bearer into an
    # identity at ANY role, gated to `Rails.env.local?` (K-539). The override
    # and both arms are gone fleet-wide, which puts the default on the path of
    # every demo driver — so the default's refusal of that bearer is now the
    # live behaviour, not a fallback nobody exercised, and it is unconditional:
    # there is no environment in which the forgery resolves.
    it "refuses a forged self-asserted agent bearer, in every environment" do
      Kiosk.configure do |c|
        c.agent_idp    = nil
        c.signing_key  = Kiosk::Server::SigningKey.generate
        c.issuer       = "https://example.test"
      end
      forged  = "agent:u-11111111-1111-4111-8111-111111111111:a-forged:r-owner"
      request = double("request", headers: { "Authorization" => "Bearer #{forged}" })

      expect(described_class.agent_idp.verify(request)).to be_nil
    end

    it "honors a configured override" do
      custom = nil_idp
      Kiosk.configure { |c| c.agent_idp = custom }
      expect(described_class.agent_idp).to be(custom)
    end
  end

  describe ".resolve" do
    it "returns the agent idp's identity first" do
      Kiosk.configure do |c|
        c.agent_idp = fixed_idp(agent_identity)
        c.user_idp  = fixed_idp(human_identity)
      end
      expect(described_class.resolve(double)).to be(agent_identity)
    end

    it "falls through to user_idp when the agent idp resolves nothing" do
      Kiosk.configure do |c|
        c.agent_idp = nil_idp
        c.user_idp  = fixed_idp(human_identity)
      end
      expect(described_class.resolve(double)).to be(human_identity)
    end

    it "returns nil when nothing resolves (caller raises 401 — fail closed)" do
      Kiosk.configure { |c| c.agent_idp = nil_idp }
      expect(described_class.resolve(double)).to be_nil
    end
  end
end
