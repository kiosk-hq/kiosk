# frozen_string_literal: true

RSpec.describe Kiosk::Mandate do
  describe Kiosk::Mandate::IntentMandate do
    let(:now) { Time.now }

    it "constructs with all fields" do
      m = described_class.new(
        id: "i-1", user_id: "u-1", agent_id: "a-1", issuer: "https://acme.example",
        scope: "book_flight", cap_amount_cents: 50_000, currency: "USD",
        expires_at: now + 3600, created_at: now, raw_jws: "eyJ..."
      )
      expect(m.id).to               eq("i-1")
      expect(m.cap_amount_cents).to eq(50_000)
      expect(m.currency).to         eq("USD")
    end

    it "is a value type (equal by fields)" do
      args = {
        id: "x", user_id: "u", agent_id: "a", issuer: "i", scope: "s",
        cap_amount_cents: 1, currency: "USD", expires_at: now,
        created_at: now, raw_jws: "j",
      }
      expect(described_class.new(**args)).to eq(described_class.new(**args))
    end
  end

  describe Kiosk::Mandate::CartMandate do
    it "constructs with all fields" do
      m = described_class.new(
        id: "c-1", intent_mandate_id: "i-1", user_id: "u-1", agent_id: "a-1",
        issuer: "https://acme.example",
        line_items: [{ name: "Espresso", price_cents: 350 }],
        total_amount_cents: 350, currency: "USD",
        expires_at: Time.now + 600, created_at: Time.now, raw_jws: "eyJ..."
      )
      expect(m.line_items.size).to     eq(1)
      expect(m.total_amount_cents).to  eq(350)
    end
  end

  describe Kiosk::Mandate::PaymentMandate do
    it "constructs with all fields" do
      now = Time.now
      m = described_class.new(
        id: "pm-1", cart_mandate_id: "c-1", user_id: "u-1", agent_id: "a-1",
        issuer: "https://acme.example", payment_method: "pm_card_visa",
        amount_cents: 350, currency: "USD",
        expires_at: now + 600, created_at: now, raw_jws: "eyJ..."
      )
      expect(m.payment_method).to eq("pm_card_visa")
      expect(m.amount_cents).to   eq(350)
    end

    it "is a value type (equal by fields)" do
      now = Time.now
      args = {
        id: "pm-1", cart_mandate_id: "c-1", user_id: "u-1", agent_id: "a-1",
        issuer: "https://acme.example", payment_method: "pm_card_visa",
        amount_cents: 350, currency: "USD",
        expires_at: now + 600, created_at: now, raw_jws: "eyJ...",
      }
      expect(described_class.new(**args)).to eq(described_class.new(**args))
    end
  end

  describe Kiosk::Mandate::Settlement do
    it "constructs with all fields" do
      m = described_class.new(
        id: "s-1", cart_mandate_id: "c-1", user_id: "u-1", agent_id: "a-1",
        issuer: "https://acme.example", psp_reference: "pi_abc",
        settled_amount_cents: 350, currency: "USD",
        settled_at: Time.now, raw_jws: ""
      )
      expect(m.psp_reference).to        eq("pi_abc")
      expect(m.settled_amount_cents).to eq(350)
    end
  end
end
