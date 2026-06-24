# frozen_string_literal: true

RSpec.describe Kiosk::Server::MandateVerifier do
  let(:agent_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:issuer)    { "https://demo.example" }
  let(:identity)  { build_identity(agent_id: "agent-1", user_id: "u-1") }
  let(:future)    { (Time.now + 600).to_i }

  before do
    Kiosk.reset!
    Kiosk.configure { |c| c.issuer = issuer }
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:agent_payment_key).with("agent-1").and_return(agent_key.public_key)
  end

  def sign(payload) = JWT.encode(payload, agent_key, "RS256")

  # Base claims every well-formed mandate carries; examples override to
  # exercise a rejection path.
  def base(**over)
    { iss: issuer, agent_id: "agent-1", user_id: "u-1", exp: future, iat: Time.now.to_i }.merge(over)
  end

  let(:intent_payload) do
    base(id: "intent-1", scope: "groceries", cap_amount_cents: 5000, currency: "eur")
  end

  let(:cart_payload) do
    base(id: "cart-1", intent_mandate_id: "intent-1",
         line_items: [{ sku: "pizza", qty: 1 }], total_amount_cents: 1599, currency: "eur")
  end

  let(:intent) do
    described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity)
  end

  # ─── verify_intent ───────────────────────────────────────────────────

  describe ".verify_intent" do
    it "returns an IntentMandate for a valid agent-signed JWS" do
      m = described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity)
      expect(m).to be_a(Kiosk::Mandate::IntentMandate)
      expect(m.id).to               eq("intent-1")
      expect(m.cap_amount_cents).to eq(5000)
      expect(m.scope).to            eq("groceries")
      expect(m.currency).to         eq("eur")
      expect(m.issuer).to           eq(issuer)
    end

    it "rejects a wrong issuer" do
      bad = intent_payload.merge(iss: "https://evil.example")
      expect { described_class.verify_intent(raw_jws: sign(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end

    it "rejects a JWS signed by an unknown key" do
      forged = JWT.encode(intent_payload, OpenSSL::PKey::RSA.generate(2048), "RS256")
      expect { described_class.verify_intent(raw_jws: forged, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end

    it "rejects a mandate with no exp claim" do
      no_exp = intent_payload.reject { |k, _| k == :exp }
      expect { described_class.verify_intent(raw_jws: sign(no_exp), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /exp/i)
    end

    it "rejects when agent_id in the payload does not match the authenticated identity" do
      bad = intent_payload.merge(agent_id: "someone-else")
      expect { described_class.verify_intent(raw_jws: sign(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end

    it "rejects when user_id in the payload does not match the authenticated identity" do
      bad = intent_payload.merge(user_id: "u-999")
      expect { described_class.verify_intent(raw_jws: sign(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end
  end

  # ─── verify_cart ─────────────────────────────────────────────────────

  describe ".verify_cart" do
    it "returns a CartMandate bound to the intent with total within cap" do
      cart = described_class.verify_cart(raw_jws: sign(cart_payload), identity: identity, intent: intent)
      expect(cart).to be_a(Kiosk::Mandate::CartMandate)
      expect(cart.total_amount_cents).to eq(1599)
      expect(cart.intent_mandate_id).to  eq("intent-1")
    end

    it "rejects a cart not bound to the intent" do
      bad = cart_payload.merge(intent_mandate_id: "intent-OTHER")
      expect { described_class.verify_cart(raw_jws: sign(bad), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /bound/)
    end

    it "rejects a cart whose total exceeds the intent cap" do
      over = cart_payload.merge(total_amount_cents: 99_999)
      expect { described_class.verify_cart(raw_jws: sign(over), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /cap/)
    end

    it "applies the shared decode checks (wrong issuer rejected)" do
      bad = cart_payload.merge(iss: "https://evil.example")
      expect { described_class.verify_cart(raw_jws: sign(bad), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end

    it "applies the shared decode checks (missing exp rejected)" do
      no_exp = cart_payload.reject { |k, _| k == :exp }
      expect { described_class.verify_cart(raw_jws: sign(no_exp), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /exp/i)
    end

    it "applies the shared decode checks (principal mismatch rejected)" do
      bad = cart_payload.merge(user_id: "u-999")
      expect { described_class.verify_cart(raw_jws: sign(bad), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end
  end
end
