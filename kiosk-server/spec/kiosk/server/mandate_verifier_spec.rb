# frozen_string_literal: true

RSpec.describe Kiosk::Server::MandateVerifier do
  let(:agent_key) { OpenSSL::PKey::RSA.generate(2048) }

  before do
    Kiosk.reset!
    Kiosk.configure { |c| c.issuer = "https://demo.example" }
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:agent_payment_key).with("agent-1").and_return(agent_key.public_key)
  end

  def sign(payload) = JWT.encode(payload, agent_key, "RS256")

  let(:cart_payload) do
    { id: "cart-1", intent_mandate_id: "intent-1", user_id: "user-1", agent_id: "agent-1",
      iss: "https://demo.example", line_items: [{ sku: "pizza", qty: 1 }],
      total_amount_cents: 1599, currency: "eur", exp: (Time.now + 600).to_i, iat: Time.now.to_i }
  end

  it "returns a CartMandate for a valid agent-signed JWS" do
    cart = described_class.verify_cart(raw_jws: sign(cart_payload), agent_id: "agent-1")
    expect(cart).to be_a(Kiosk::Mandate::CartMandate)
    expect(cart.total_amount_cents).to eq(1599)
  end

  it "rejects a wrong issuer" do
    bad = cart_payload.merge(iss: "https://evil.example")
    expect { described_class.verify_cart(raw_jws: sign(bad), agent_id: "agent-1") }
      .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
  end

  it "rejects a JWS signed by an unknown key" do
    forged = JWT.encode(cart_payload, OpenSSL::PKey::RSA.generate(2048), "RS256")
    expect { described_class.verify_cart(raw_jws: forged, agent_id: "agent-1") }
      .to raise_error(Kiosk::Server::Errors::Forbidden)
  end
end
