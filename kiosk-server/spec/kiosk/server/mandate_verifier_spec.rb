# frozen_string_literal: true

RSpec.describe Kiosk::Server::MandateVerifier do
  let(:agent_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:issuer)    { "https://demo.example" }
  let(:identity)  { build_identity(agent_id: "agent-1", user_id: "u-1") }
  let(:future)    { (Time.now + 600).to_i }

  before do
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

  let(:cart_mandate) do
    described_class.verify_cart(raw_jws: sign(cart_payload), identity: identity, intent: intent)
  end

  let(:payment_payload) do
    base(id: "pay-1", cart_mandate_id: "cart-1", payment_method: "pm_card_visa",
         amount_cents: 1599, currency: "eur")
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

    # agent_payment_key raises Kiosk::AgentIdentityProviders::InvalidToken
    # when the authenticated (non-nil) agent_id has no live kiosk.agents row
    # (revoked/deleted between auth and now). InvalidToken is NOT an Errors::Base,
    # so it escaped decode_and_check's JWT-only rescues and the controller's
    # Errors::Base rescue as an HTTP 500. It must be caught → clean 403 Forbidden.
    it "rejects (403, not 500) when the agent has no registered payment key" do
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:agent_payment_key).with("agent-1")
        .and_raise(Kiosk::AgentIdentityProviders::InvalidToken, "no key for agent agent-1")
      expect { described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /payment key|revoked|unknown/)
    end

    it "rejects a mandate with no exp claim" do
      no_exp = intent_payload.reject { |k, _| k == :exp }
      expect { described_class.verify_intent(raw_jws: sign(no_exp), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /exp/i)
    end

    # id and iat are spec-MUST claims. The payloads below are otherwise
    # fully valid (correct key, iss, principal, exp) — they passed the old
    # exp-only check and must now be rejected on presence alone.
    it "rejects a mandate with no id claim" do
      no_id = intent_payload.reject { |k, _| k == :id }
      expect { described_class.verify_intent(raw_jws: sign(no_id), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /id/i)
    end

    it "rejects a mandate with no iat claim" do
      no_iat = intent_payload.reject { |k, _| k == :iat }
      expect { described_class.verify_intent(raw_jws: sign(no_iat), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /iat/i)
    end

    it "rejects when agent_id in the payload does not match the authenticated identity" do
      bad = intent_payload.merge(agent_id: "someone-else")
      expect { described_class.verify_intent(raw_jws: sign(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end

    # cap_amount_cents is a REQUIRED intent field. ABSENT (nil) would
    # nil-coerce to 0 in the verify_cart cap comparison, making it vacuous — an
    # absent cap must be rejected on presence, before any .to_i.
    it "rejects an intent missing cap_amount_cents (absent, not 0)" do
      no_cap = intent_payload.reject { |k, _| k == :cap_amount_cents }
      expect { described_class.verify_intent(raw_jws: sign(no_cap), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /cap_amount_cents/)
    end

    # Currency is a REQUIRED mandate field (spec AP2 table). ABSENT on
    # both intent and cart makes the cap guard (nil != nil) and the
    # verify_payment match (nil == nil) pass vacuously, then a NOT NULL currency
    # column 500s after partial persist — reject on presence instead.
    it "rejects an intent missing currency (absent)" do
      no_cur = intent_payload.reject { |k, _| k == :currency }
      expect { described_class.verify_intent(raw_jws: sign(no_cur), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
    end

    it "rejects when user_id in the payload does not match the authenticated identity" do
      bad = intent_payload.merge(user_id: "u-999")
      expect { described_class.verify_intent(raw_jws: sign(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end

    # On a bigint-PK host the authenticated Identity carries an Integer
    # user_id/agent_id (the token `sub` round-trips as bigint), while the agent
    # signs the mandate with the String the register response returned. The
    # principal check must compare as STRING on both sides, or every mandate on
    # a bigint host is wrongly Forbidden.
    context "on a bigint-PK host (Integer identity, String mandate principal)" do
      let(:identity)   { build_identity(agent_id: 7, user_id: 42) }
      let(:big_intent) { intent_payload.merge(agent_id: "7", user_id: "42") }

      before do
        allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
          .to receive(:agent_payment_key).with(7).and_return(agent_key.public_key)
      end

      it "verifies an Integer identity against a String mandate principal" do
        m = described_class.verify_intent(raw_jws: sign(big_intent), identity: identity)
        expect(m).to be_a(Kiosk::Mandate::IntentMandate)
        expect(m.user_id).to  eq("42")
        expect(m.agent_id).to eq("7")
      end

      it "still rejects a genuinely different principal (43 != 42)" do
        wrong = big_intent.merge(user_id: "43")
        expect { described_class.verify_intent(raw_jws: sign(wrong), identity: identity) }
          .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
      end
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

    # The cap comparison is currency-blind without this guard — a 4999
    # USD cart would slip under a 5000 EUR cap. The intent is 5000 eur (see
    # intent_payload); a same-number-under-cap cart in a DIFFERENT currency
    # must be rejected on currency, not silently accepted.
    it "rejects a cart priced in a different currency than the intent cap (4999 USD vs 5000 EUR cap)" do
      usd = cart_payload.merge(total_amount_cents: 4999, currency: "usd")
      expect { described_class.verify_cart(raw_jws: sign(usd), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
    end

    # total_amount_cents is a REQUIRED cart field. ABSENT (nil) would
    # nil-coerce to 0, satisfying the cap comparison (0 <= 5000) vacuously and
    # persisting a 0-cent cart row. It must be rejected on presence, before the
    # .to_i — an absent total is NOT a valid within-cap cart.
    it "rejects a cart missing total_amount_cents (absent, not 0)" do
      no_total = cart_payload.reject { |k, _| k == :total_amount_cents }
      expect { described_class.verify_cart(raw_jws: sign(no_total), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /total_amount_cents/)
    end

    # Absent currency on the cart (see the intent-side rationale).
    it "rejects a cart missing currency (absent)" do
      no_cur = cart_payload.reject { |k, _| k == :currency }
      expect { described_class.verify_cart(raw_jws: sign(no_cur), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
    end

    # K-741 / LINE-ITEMS-REQUIRED (Phil, 2026-08-16). `line_items` was optional
    # while the settlement path already depended on it: an assistant could omit
    # it, pay successfully, and leave the operator holding a settlement it
    # cannot match to any domain object — a degraded audit and reconciliation
    # trail with no error raised anywhere. Required now, in the spec table, in
    # the JSON Schema, and here.
    it "rejects a cart missing line_items (absent)" do
      no_items = cart_payload.reject { |k, _| k == :line_items }
      expect { described_class.verify_cart(raw_jws: sign(no_items), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /line_items/)
    end

    # An explicit null is the same omission spelled differently — a JWS payload
    # is JSON, and `{"line_items": null}` must not slip past a presence check
    # written as `key?`.
    it "rejects a cart whose line_items are explicitly null" do
      nulled = cart_payload.merge(line_items: nil)
      expect { described_class.verify_cart(raw_jws: sign(nulled), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /line_items/)
    end

    # The field is typed `array` in mandates.schema.json. A scalar or an object
    # would reach the demos' `line_items @> …::jsonb` containment guard and the
    # `my_orders` join as something neither can read.
    it "rejects a cart whose line_items are not an array" do
      scalar = cart_payload.merge(line_items: "pizza")
      expect { described_class.verify_cart(raw_jws: sign(scalar), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /line_items must be an array/)
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

  # ─── K-551: robustness — a clean 4xx, never a 500 ────────────────────
  # A malformed input must not crash the verifier. A numeric-STRING exp slips
  # past JWT's expiry check (it coerces via to_i) then blows up in
  # `Time.at(String)`; a string iat blows up the same way (iat is not verified
  # by JWT at all); and an exp far in the future is an effectively non-expiring
  # mandate, which the spec says MUST be rejected.
  describe "input robustness (clean 4xx, not 500)" do
    # Hand-craft a signed JWS, bypassing JWT.encode's own claim verification —
    # exactly what a hostile client does. A numeric-STRING exp slips past JWT's
    # decode-time expiry check (it coerces) then 500s in Time.at(String).
    def craft(payload)
      require "base64"
      header = Base64.urlsafe_encode64(JSON.generate(alg: "RS256", typ: "JWT")).delete("=")
      body   = Base64.urlsafe_encode64(JSON.generate(payload)).delete("=")
      input  = "#{header}.#{body}"
      sig    = Base64.urlsafe_encode64(agent_key.sign(OpenSSL::Digest.new("SHA256"), input)).delete("=")
      "#{input}.#{sig}"
    end

    it "rejects a numeric-string exp as bad_request instead of 500ing in Time.at" do
      bad = intent_payload.merge(exp: (Time.now.to_i + 600).to_s)
      expect { described_class.verify_intent(raw_jws: craft(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /exp/)
    end

    it "rejects a string iat as bad_request instead of 500ing in Time.at" do
      bad = intent_payload.merge(iat: "yesterday")
      expect { described_class.verify_intent(raw_jws: craft(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /iat/)
    end

    it "rejects an effectively non-expiring mandate (exp beyond the max lifetime)" do
      forever = intent_payload.merge(exp: Time.now.to_i + (400 * 24 * 3600))
      expect { described_class.verify_intent(raw_jws: sign(forever), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /lifetime/)
    end

    it "still accepts a normal short-lived mandate (well within the max lifetime)" do
      m = described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity)
      expect(m).to be_a(Kiosk::Mandate::IntentMandate)
    end
  end

  # ─── K-543: non-positive amounts launder the spending cap ────────────
  # A negative cart total slips under the cap (−100000 <= 5000), matches a
  # negative payment, settles, and drives the settlements SUM negative —
  # permanently RAISING the agent's effective cap by that amount. Zero is
  # equally invalid. Every mandate amount MUST be a positive integer of cents.
  describe "non-positive amounts" do
    it "rejects a cart with a NEGATIVE total_amount_cents (the launder vector)" do
      neg = cart_payload.merge(total_amount_cents: -100_000)
      expect { described_class.verify_cart(raw_jws: sign(neg), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end

    it "rejects a cart with a ZERO total_amount_cents" do
      zero = cart_payload.merge(total_amount_cents: 0)
      expect { described_class.verify_cart(raw_jws: sign(zero), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end

    it "rejects an intent with a NEGATIVE cap_amount_cents" do
      neg = intent_payload.merge(cap_amount_cents: -5000)
      expect { described_class.verify_intent(raw_jws: sign(neg), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end

    it "rejects an intent with a ZERO cap_amount_cents" do
      zero = intent_payload.merge(cap_amount_cents: 0)
      expect { described_class.verify_intent(raw_jws: sign(zero), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end

    it "rejects a payment with a NEGATIVE amount_cents" do
      neg = payment_payload.merge(amount_cents: -1599)
      expect { described_class.verify_payment(raw_jws: sign(neg), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end
  end

  # ─── verify_payment ──────────────────────────────────────────────────

  describe ".verify_payment" do
    it "returns a PaymentMandate for a valid signed JWS bound to the cart" do
      pm = described_class.verify_payment(raw_jws: sign(payment_payload), identity: identity, cart: cart_mandate)
      expect(pm).to be_a(Kiosk::Mandate::PaymentMandate)
      expect(pm.id).to              eq("pay-1")
      expect(pm.cart_mandate_id).to eq("cart-1")
      expect(pm.payment_method).to  eq("pm_card_visa")
      expect(pm.amount_cents).to    eq(1599)
      expect(pm.currency).to        eq("eur")
      expect(pm.issuer).to          eq(issuer)
    end

    it "rejects a payment not bound to the presented cart (wrong cart_mandate_id)" do
      bad = payment_payload.merge(cart_mandate_id: "cart-OTHER")
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /bound/)
    end

    it "rejects a payment whose amount_cents does not match the cart total" do
      bad = payment_payload.merge(amount_cents: 99_999)
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /amount/)
    end

    it "rejects a payment whose amount is under the cart total" do
      bad = payment_payload.merge(amount_cents: 100)
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /amount/)
    end

    it "rejects a payment with a mismatched currency" do
      bad = payment_payload.merge(currency: "usd")
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency|amount/)
    end

    # SetupIntent model: the assistant authorises but never presents a card —
    # the provider's PSP resolves the principal's on-file card at capture time.
    # payment_method is therefore OPTIONAL in the mandate.
    it "accepts a payment with a nil/absent payment_method (SetupIntent model: on-file card)" do
      no_pm = payment_payload.reject { |k, _| k == :payment_method }
      pm = described_class.verify_payment(raw_jws: sign(no_pm), identity: identity, cart: cart_mandate)
      expect(pm).to be_a(Kiosk::Mandate::PaymentMandate)
      expect(pm.payment_method).to be_nil
    end

    it "accepts a payment with an empty payment_method" do
      empty_pm = payment_payload.merge(payment_method: "")
      pm = described_class.verify_payment(raw_jws: sign(empty_pm), identity: identity, cart: cart_mandate)
      expect(pm.payment_method).to eq("")
    end

    # amount_cents is a REQUIRED payment field. ABSENT (nil) would
    # nil-coerce to 0 in the amount-match check; against a same-absent (0) cart
    # total it would "match" and persist a 0-cent payment row. Reject on
    # presence, before the .to_i — an absent amount is not a valid payment.
    it "rejects a payment missing amount_cents (absent, not 0)" do
      no_amount = payment_payload.reject { |k, _| k == :amount_cents }
      expect { described_class.verify_payment(raw_jws: sign(no_amount), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /amount_cents/)
    end

    it "applies the shared decode checks (wrong signer rejected)" do
      forged = JWT.encode(payment_payload, OpenSSL::PKey::RSA.generate(2048), "RS256")
      expect { described_class.verify_payment(raw_jws: forged, identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end

    it "applies the shared decode checks (expired mandate rejected)" do
      past = payment_payload.merge(exp: (Time.now - 60).to_i)
      expect { described_class.verify_payment(raw_jws: sign(past), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /expired/)
    end

    it "applies the shared decode checks (missing exp rejected)" do
      no_exp = payment_payload.reject { |k, _| k == :exp }
      expect { described_class.verify_payment(raw_jws: sign(no_exp), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /exp/i)
    end

    it "applies the shared decode checks (wrong issuer rejected)" do
      bad = payment_payload.merge(iss: "https://evil.example")
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end

    it "applies the shared decode checks (principal mismatch rejected)" do
      bad = payment_payload.merge(user_id: "u-999")
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end
  end
end
