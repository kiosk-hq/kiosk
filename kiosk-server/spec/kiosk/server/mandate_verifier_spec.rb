# frozen_string_literal: true

module MandateVerifierSpec
  def sign(payload) = JWT.encode(payload, agent_key, 'RS256')

  # Base claims every well-formed mandate carries; examples override to
  # exercise a rejection path.
  def base(**over)
    { iss: issuer, agent_id: 'agent-1', user_id: 'u-1', exp: future, iat: Time.now.to_i }.merge(over)
  end

  # The three presence examples. Each sends an otherwise valid payload
  # (correct key, iss, principal, exp) minus exactly ONE claim, so only the
  # presence check can refuse it. Each asserts the published sentence, a hint
  # that lists the required claims from our own list, and no byte of the JWT
  # gem's own wording.
  def expect_missing_required_claim(&)
    expect(&)
      .to raise_error(Kiosk::Server::Errors::Forbidden) { |e|
        expect(e.message).to eq('mandate missing a required claim')
        expect(e.hint).to include('id', 'user_id', 'agent_id', 'iss', 'iat', 'exp')
        expect("#{e.message} #{e.hint}").not_to include('Missing required claim')
      }
  end

  # Hand-craft a signed JWS, bypassing JWT.encode's own claim verification —
  # exactly what a hostile client does. A numeric-STRING exp slips past JWT's
  # decode-time expiry check (it coerces) then 500s in Time.at(String).
  def craft(payload)
    require 'base64'
    header = Base64.urlsafe_encode64(JSON.generate(alg: 'RS256', typ: 'JWT')).delete('=')
    body   = Base64.urlsafe_encode64(JSON.generate(payload)).delete('=')
    input  = "#{header}.#{body}"
    sig    = Base64.urlsafe_encode64(agent_key.sign(OpenSSL::Digest.new('SHA256'), input)).delete('=')
    "#{input}.#{sig}"
  end
end

RSpec.shared_context 'mandate verifier spec: agent' do
  include MandateVerifierSpec

  let(:agent_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:issuer)    { 'https://demo.example' }
  let(:identity)  { build_identity(agent_id: 'agent-1', user_id: 'u-1') }
  let(:future)    { (Time.current + 600).to_i }

  before do
    Kiosk.configure { |c| c.issuer = issuer }
    allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
      .to receive(:agent_payment_key).with('agent-1').and_return(agent_key.public_key)
  end
end

RSpec.shared_context 'mandate verifier spec: verifier' do
  include_context 'mandate verifier spec: agent'

  let(:intent_payload) do
    base(id: 'intent-1', scope: 'groceries', cap_amount_cents: 5000, currency: 'eur')
  end

  let(:cart_payload) do
    base(id: 'cart-1', intent_mandate_id: 'intent-1',
         line_items: [{ sku: 'pizza', qty: 1 }], total_amount_cents: 1599, currency: 'eur')
  end

  let(:intent) do
    described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity)
  end

  let(:cart_mandate) do
    described_class.verify_cart(raw_jws: sign(cart_payload), identity: identity, intent: intent)
  end

  let(:payment_payload) do
    base(id: 'pay-1', cart_mandate_id: 'cart-1', payment_method: 'pm_card_visa',
         amount_cents: 1599, currency: 'eur')
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  # ─── verify_intent ───────────────────────────────────────────────────
  describe '.verify_intent' do
    it 'returns an IntentMandate for a valid agent-signed JWS' do
      m = described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity)
      expect(m).to be_a(Kiosk::Mandate::IntentMandate)
      expect(m.id).to               eq('intent-1')
      expect(m.cap_amount_cents).to eq(5000)
      expect(m.scope).to            eq('groceries')
      expect(m.currency).to         eq('eur')
      expect(m.issuer).to           eq(issuer)
    end

    it 'rejects a wrong issuer' do
      bad = intent_payload.merge(iss: 'https://evil.example')
      expect { described_class.verify_intent(raw_jws: sign(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end

    it 'rejects a JWS signed by an unknown key' do
      forged = JWT.encode(intent_payload, OpenSSL::PKey::RSA.generate(2048), 'RS256')
      expect { described_class.verify_intent(raw_jws: forged, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    # agent_payment_key raises Kiosk::AgentIdentityProviders::InvalidToken
    # when the authenticated (non-nil) agent_id has no live kiosk.agents row
    # (revoked/deleted between auth and now). InvalidToken is NOT an Errors::Base,
    # so it escaped decode_and_check's JWT-only rescues and the controller's
    # Errors::Base rescue as an HTTP 500. It must be caught → clean 403 Forbidden.
    it 'rejects (403, not 500) when the agent has no registered payment key' do
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:agent_payment_key).with('agent-1')
        .and_raise(Kiosk::AgentIdentityProviders::InvalidToken, 'no key for agent agent-1')
      expect { described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /payment key|revoked|unknown/)
    end

    it 'rejects a mandate with no exp claim' do
      no_exp = intent_payload.except(:exp)
      expect_missing_required_claim do
        described_class.verify_intent(raw_jws: sign(no_exp), identity: identity)
      end
    end

    # id and iat are spec-MUST claims. The payloads below are otherwise
    # fully valid (correct key, iss, principal, exp), so only the presence
    # check can refuse them.
    it 'rejects a mandate with no id claim' do
      no_id = intent_payload.except(:id)
      expect_missing_required_claim do
        described_class.verify_intent(raw_jws: sign(no_id), identity: identity)
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    it 'rejects a mandate with no iat claim' do
      no_iat = intent_payload.except(:iat)
      expect_missing_required_claim do
        described_class.verify_intent(raw_jws: sign(no_iat), identity: identity)
      end
    end

    # The hint is not decoration: it is the ONLY place the wire names the
    # claims, so it must name the ones the decode actually requires and not a
    # hand-kept second list beside them.
    it 'publishes the claims the decode enforces, not a copy of them' do
      no_exp = intent_payload.except(:exp)
      expect { described_class.verify_intent(raw_jws: sign(no_exp), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden) { |e|
          expect(e.hint).to eq("a mandate carries #{described_class::REQUIRED_CLAIMS.join(', ')}")
        }
    end

    it 'rejects when agent_id in the payload does not match the authenticated identity' do
      bad = intent_payload.merge(agent_id: 'someone-else')
      expect { described_class.verify_intent(raw_jws: sign(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  # §11.1: the principal and issuer claims are refused for ABSENCE, before
  # the principal and issuer comparisons read them.
  describe '.verify_intent' do
    it 'rejects a mandate with no user_id claim' do
      expect_missing_required_claim do
        described_class.verify_intent(raw_jws: sign(intent_payload.except(:user_id)), identity: identity)
      end
    end

    it 'rejects a mandate with no agent_id claim' do
      expect_missing_required_claim do
        described_class.verify_intent(raw_jws: sign(intent_payload.except(:agent_id)), identity: identity)
      end
    end

    it 'rejects a mandate with no iss claim' do
      expect_missing_required_claim do
        described_class.verify_intent(raw_jws: sign(intent_payload.except(:iss)), identity: identity)
      end
    end

    it 'rejects a mandate signed with HS256 instead of RS256' do
      hmac = JWT.encode(intent_payload, 'shared-secret', 'HS256')
      expect { described_class.verify_intent(raw_jws: hmac, identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, 'mandate signature invalid')
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    # cap_amount_cents is a REQUIRED intent field. ABSENT (nil) would
    # nil-coerce to 0 in the verify_cart cap comparison, making it vacuous — an
    # absent cap must be rejected on presence, before any .to_i.
    it 'rejects an intent missing cap_amount_cents (absent, not 0)' do
      no_cap = intent_payload.except(:cap_amount_cents)
      expect { described_class.verify_intent(raw_jws: sign(no_cap), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /cap_amount_cents/)
    end

    # Currency is a REQUIRED mandate field (spec AP2 table). ABSENT on
    # both intent and cart makes the cap guard (nil != nil) and the
    # verify_payment match (nil == nil) pass vacuously, then a NOT NULL currency
    # column 500s after partial persist — reject on presence instead.
    it 'rejects an intent missing currency (absent)' do
      no_cur = intent_payload.except(:currency)
      expect { described_class.verify_intent(raw_jws: sign(no_cur), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    # Presence is not enough: §11.2 compares the three mandates' currencies to
    # EACH OTHER and never to a domain, so `""` on intent, cart and payment is
    # consistent all the way through the chain, reaches the PSP as the currency
    # of a real charge, and becomes the key of the spending-cap tally. A
    # non-String does the same and binds a type the NOT NULL currency column is not.
    #
    # `Forbidden` BY CLASS, not by message: `currency` is one of the seven limbs of
    # the §9.1 mandate carve-out, so a silent move to `BadRequest` must redden here
    # (SPEC-184/SPEC-185 draw that boundary and neither 400 check is this one).
    #
    # The currency domain is the next group: an ISO 4217 alpha-3 shape. The
    # verifier refuses "US" and "Euro", and it accepts "xyz".
    describe 'malformed currency' do
      it 'rejects an intent whose currency is an EMPTY string' do
        empty = intent_payload.merge(currency: '')
        expect { described_class.verify_intent(raw_jws: sign(empty), identity: identity) }
          .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
      end

      it 'rejects an intent whose currency is all whitespace' do
        blank = intent_payload.merge(currency: '   ')
        expect { described_class.verify_intent(raw_jws: sign(blank), identity: identity) }
          .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
      end

      it 'rejects an intent whose currency is NOT A STRING' do
        numeric = intent_payload.merge(currency: 5)
        expect { described_class.verify_intent(raw_jws: sign(numeric), identity: identity) }
          .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
      end

      it 'answers 403, not 400 — currency is inside the §9.1 mandate carve-out' do
        empty = intent_payload.merge(currency: '')
        expect { described_class.verify_intent(raw_jws: sign(empty), identity: identity) }
          .to(raise_error { |e| expect(e.class::HTTP_STATUS).to eq(403) })
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    describe 'malformed currency' do
      # The positive control: the guard is not a blanket refuser.
      it 'accepts a well-formed currency' do
        m = described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity)
        expect(m.currency).to eq('eur')
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    describe 'malformed currency' do
      # ── The currency domain: an ISO 4217 alpha-3 shape ──
      #
      # Each clause is a place a regression would land:
      #   * "Euro" is a NAME, not a code, and is refused.
      #   * The status is 403, not 400: `currency` is one of the seven limbs of
      #     the §9.1 mandate carve-out.
      #   * The refusal is on the SHAPE, so `"xyz"` still passes — stated here
      #     rather than left to be discovered, because it is the operator's
      #     MINIMUM refusal and not the whole domain (§11.1). The PSP refuses the
      #     rest one call later, and no list in this repository could do better:
      #     the vendored Stripe client documents a server-side supported set and
      #     enumerates nothing.
      describe 'the currency domain is ISO 4217 alpha-3' do
        it 'refuses a currency NAME such as Euro' do
          odd = intent_payload.merge(currency: 'Euro')
          expect { described_class.verify_intent(raw_jws: sign(odd), identity: identity) }
            .to raise_error(Kiosk::Server::Errors::Forbidden, /ISO 4217/)
        end

        it 'refuses a two-letter country code: US is not a currency' do
          expect do
            described_class.verify_intent(raw_jws: sign(intent_payload.merge(currency: 'US')),
                                          identity: identity)
          end.to raise_error(Kiosk::Server::Errors::Forbidden, /ISO 4217/)
        end

        # ISO 4217 publishes a numeric-3 code beside every alpha-3 one, so «an
        # ISO 4217 code» read literally admits "978". §11.1 says alpha-3 in those
        # words BECAUSE the PSP takes letters: the vendored Stripe client
        # documents `currency` as «Three-letter ISO currency code, in lowercase».
        it 'refuses the NUMERIC-3 spelling ISO 4217 also publishes' do
          expect do
            described_class.verify_intent(raw_jws: sign(intent_payload.merge(currency: '978')),
                                          identity: identity)
          end.to raise_error(Kiosk::Server::Errors::Forbidden, /ISO 4217/)
        end
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    describe 'malformed currency' do
      describe 'the currency domain is ISO 4217 alpha-3' do
        it 'answers 403, not 400 — a domain refusal is inside the §9.1 mandate carve-out' do
          expect do
            described_class.verify_intent(raw_jws: sign(intent_payload.merge(currency: 'Euro')),
                                          identity: identity)
          end.to(raise_error { |e| expect(e.class::HTTP_STATUS).to eq(403) })
        end

        # The control: every code this repository spells must still settle.
        # gbp is getgrocery's glyph map and jpy is kiosk-redteam's
        # WrongCurrencyCart ALTERNATIVES.
        it 'settles eur, usd, gbp and jpy — either case, and padded' do
          { 'eur' => 'eur', 'EUR' => 'eur', 'usd' => 'usd', 'USD' => 'usd',
            'gbp' => 'gbp', 'jpy' => 'jpy', '  eur ' => 'eur' }.each do |sent, canonical|
            m = described_class.verify_intent(
              raw_jws: sign(intent_payload.merge(currency: sent)), identity: identity
            )
            expect(m.currency).to eq(canonical), "#{sent.inspect} should settle as #{canonical.inspect}"
          end
        end
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    describe 'malformed currency' do
      describe 'the currency domain is ISO 4217 alpha-3' do
        # The shape is the MINIMUM refusal; an allow-list would change this example.
        it 'accepts three letters that name no currency — the shape is the minimum, not the domain' do
          m = described_class.verify_intent(
            raw_jws: sign(intent_payload.merge(currency: 'xyz')), identity: identity
          )
          expect(m.currency).to eq('xyz')
        end
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    # ── Case and whitespace are NOT identity ─────────────────────────────
    #
    # The spending-cap tally of §11.5 is keyed on the currency string. Without
    # canonicalisation, an assistant that alternated `"eur"` and `"EUR"`
    # between chains would get a FRESH cap for each spelling.
    describe 'currency is canonicalised at the boundary' do
      it 'downcases an intent currency' do
        m = described_class.verify_intent(raw_jws: sign(intent_payload.merge(currency: 'EUR')),
                                          identity: identity)
        expect(m.currency).to eq('eur')
      end

      it 'strips surrounding whitespace off an intent currency' do
        m = described_class.verify_intent(raw_jws: sign(intent_payload.merge(currency: '  eur ')),
                                          identity: identity)
        expect(m.currency).to eq('eur')
      end

      it 'canonicalises a cart currency' do
        c = described_class.verify_cart(raw_jws: sign(cart_payload.merge(currency: 'EUR')),
                                        identity: identity, intent: intent)
        expect(c.currency).to eq('eur')
      end

      it 'canonicalises a payment currency' do
        p = described_class.verify_payment(raw_jws: sign(payment_payload.merge(currency: 'EUR')),
                                           identity: identity, cart: cart_mandate)
        expect(p.currency).to eq('eur')
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    describe 'currency is canonicalised at the boundary' do
      # The §11.2 comparisons run on the canonical values, so a chain that
      # spells one code two ways is ONE currency rather than a 403. The spec
      # leaves case-sensitivity to the operator (§11.1); this is the operator's
      # rule, taken here so the comparison and the tally key agree.
      it 'accepts an EUR cart under an eur intent (one currency, not a mismatch)' do
        upper_intent = described_class.verify_intent(
          raw_jws: sign(intent_payload.merge(currency: 'EUR')), identity: identity
        )
        expect do
          described_class.verify_cart(raw_jws: sign(cart_payload), identity: identity,
                                      intent: upper_intent)
        end.not_to raise_error
      end

      it 'accepts an EUR payment against an eur cart' do
        expect do
          described_class.verify_payment(raw_jws: sign(payment_payload.merge(currency: 'EUR')),
                                         identity: identity, cart: cart_mandate)
        end.not_to raise_error
      end

      # The positive control the two examples above need: folding CASE must not
      # fold two genuinely different codes together.
      it 'still rejects a usd cart under an eur intent cap' do
        usd = cart_payload.merge(currency: 'usd')
        expect { described_class.verify_cart(raw_jws: sign(usd), identity: identity, intent: intent) }
          .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    describe 'currency is canonicalised at the boundary' do
      it 'still rejects a USD payment against an eur cart' do
        usd = payment_payload.merge(currency: 'USD')
        expect do
          described_class.verify_payment(raw_jws: sign(usd), identity: identity, cart: cart_mandate)
        end.to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    it 'rejects when user_id in the payload does not match the authenticated identity' do
      bad = intent_payload.merge(user_id: 'u-999')
      expect { described_class.verify_intent(raw_jws: sign(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_intent' do
    # On a bigint-PK host the authenticated Identity carries an Integer
    # user_id/agent_id (the token `sub` round-trips as bigint), while the agent
    # signs the mandate with the String the register response returned. The
    # principal check must compare as STRING on both sides, or every mandate on
    # a bigint host is wrongly Forbidden.
    context 'on a bigint-PK host (Integer identity, String mandate principal)' do
      let(:identity)   { build_identity(agent_id: 7, user_id: 42) }

      let(:big_intent) { intent_payload.merge(agent_id: '7', user_id: '42') }

      before do
        allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
          .to receive(:agent_payment_key).with(7).and_return(agent_key.public_key)
      end

      it 'verifies an Integer identity against a String mandate principal' do
        m = described_class.verify_intent(raw_jws: sign(big_intent), identity: identity)
        expect(m).to be_a(Kiosk::Mandate::IntentMandate)
        expect(m.user_id).to  eq('42')
        expect(m.agent_id).to eq('7')
      end

      it 'still rejects a genuinely different principal (43 != 42)' do
        wrong = big_intent.merge(user_id: '43')
        expect { described_class.verify_intent(raw_jws: sign(wrong), identity: identity) }
          .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
      end
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  # ─── verify_cart ─────────────────────────────────────────────────────
  describe '.verify_cart' do
    it 'returns a CartMandate bound to the intent with total within cap' do
      cart = described_class.verify_cart(raw_jws: sign(cart_payload), identity: identity, intent: intent)
      expect(cart).to be_a(Kiosk::Mandate::CartMandate)
      expect(cart.total_amount_cents).to eq(1599)
      expect(cart.intent_mandate_id).to  eq('intent-1')
    end

    it 'rejects a cart not bound to the intent' do
      bad = cart_payload.merge(intent_mandate_id: 'intent-OTHER')
      expect { described_class.verify_cart(raw_jws: sign(bad), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /bound/)
    end

    it 'rejects a cart whose total exceeds the intent cap' do
      over = cart_payload.merge(total_amount_cents: 99_999)
      expect { described_class.verify_cart(raw_jws: sign(over), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /cap/)
    end

    # The cap comparison is currency-blind without this guard — a 4999
    # USD cart would slip under a 5000 EUR cap. The intent is 5000 eur (see
    # intent_payload); a same-number-under-cap cart in a DIFFERENT currency
    # must be rejected on currency, not silently accepted.
    it 'rejects a cart priced in a different currency than the intent cap (4999 USD vs 5000 EUR cap)' do
      usd = cart_payload.merge(total_amount_cents: 4999, currency: 'usd')
      expect { described_class.verify_cart(raw_jws: sign(usd), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_cart' do
    # total_amount_cents is a REQUIRED cart field. ABSENT (nil) would
    # nil-coerce to 0, satisfying the cap comparison (0 <= 5000) vacuously and
    # persisting a 0-cent cart row. It must be rejected on presence, before the
    # .to_i — an absent total is NOT a valid within-cap cart.
    it 'rejects a cart missing total_amount_cents (absent, not 0)' do
      no_total = cart_payload.except(:total_amount_cents)
      expect { described_class.verify_cart(raw_jws: sign(no_total), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /total_amount_cents/)
    end

    # Absent currency on the cart (see the intent-side rationale).
    it 'rejects a cart missing currency (absent)' do
      no_cur = cart_payload.except(:currency)
      expect { described_class.verify_cart(raw_jws: sign(no_cur), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
    end

    # The malformed-currency guard on the CART limb, where the vacuity is easiest
    # to see: `cart.currency != intent.currency` is the only currency check §11.2
    # performs, and `"" != "eur"` is TRUE, so an empty cart currency is caught by
    # the guard rather than by the binding rule. The intent here is well-formed
    # ("eur"), so nothing but `require_currency!` can be what refuses this.
    it 'rejects a cart whose currency is an EMPTY string' do
      empty = cart_payload.merge(currency: '')
      expect { described_class.verify_cart(raw_jws: sign(empty), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
    end

    it 'rejects a cart whose currency is NOT A STRING' do
      numeric = cart_payload.merge(currency: 5)
      expect { described_class.verify_cart(raw_jws: sign(numeric), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_cart' do
    # `line_items` is required: without it an assistant could pay and leave the
    # operator holding a settlement it cannot match to any domain object. The
    # spec table, the JSON Schema and the verifier require it.
    it 'rejects a cart missing line_items (absent)' do
      no_items = cart_payload.except(:line_items)
      expect { described_class.verify_cart(raw_jws: sign(no_items), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /line_items/)
    end

    # An explicit null is the same omission spelled differently — a JWS payload
    # is JSON, and `{"line_items": null}` must not slip past a presence check
    # written as `key?`.
    it 'rejects a cart whose line_items are explicitly null' do
      nulled = cart_payload.merge(line_items: nil)
      expect { described_class.verify_cart(raw_jws: sign(nulled), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /line_items/)
    end

    # The field is typed `array` in mandates.schema.json. A scalar or an object
    # would reach the demos' `line_items @> …::jsonb` containment guard and the
    # `my_orders` join as something neither can read.
    it 'rejects a cart whose line_items are not an array' do
      scalar = cart_payload.merge(line_items: 'pizza')
      expect { described_class.verify_cart(raw_jws: sign(scalar), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /line_items must be an array/)
    end

    # Presence is not enough. `[]` satisfies `required` and every check above
    # while carrying as much reconciliation value as omission, and a positive
    # `total_amount_cents` with nothing itemised under it is an unitemised
    # charge. §11.2 and `mandates.schema.json` (`minItems: 1`) refuse it; this
    # pins that the verifier refuses the same set.
    it 'rejects a cart whose line_items array is EMPTY' do
      empty = cart_payload.merge(line_items: [])
      expect { described_class.verify_cart(raw_jws: sign(empty), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /line_items must not be empty/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_cart' do
    it 'applies the shared decode checks (wrong issuer rejected)' do
      bad = cart_payload.merge(iss: 'https://evil.example')
      expect { described_class.verify_cart(raw_jws: sign(bad), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end

    it 'applies the shared decode checks (missing exp rejected)' do
      no_exp = cart_payload.except(:exp)
      expect { described_class.verify_cart(raw_jws: sign(no_exp), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden) { |e|
          expect(e.message).to eq('mandate missing a required claim')
          expect(e.hint).to include('exp')
          expect("#{e.message} #{e.hint}").not_to include('Missing required claim')
        }
    end

    it 'applies the shared decode checks (principal mismatch rejected)' do
      bad = cart_payload.merge(user_id: 'u-999')
      expect { described_class.verify_cart(raw_jws: sign(bad), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end

    it 'applies the shared decode checks (foreign signer rejected)' do
      forged = JWT.encode(cart_payload, OpenSSL::PKey::RSA.generate(2048), 'RS256')
      expect { described_class.verify_cart(raw_jws: forged, identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, 'mandate signature invalid')
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  # ─── robustness — a clean 4xx, never a 500 ───────────────────────────
  # A malformed input must not crash the verifier. A numeric-STRING exp slips
  # past JWT's expiry check (it coerces via to_i) then blows up in
  # `Time.at(String)`; a string iat blows up the same way (iat is not verified
  # by JWT at all); and an exp far in the future is an effectively non-expiring
  # mandate, which the spec says MUST be rejected.
  describe 'input robustness (clean 4xx, not 500)' do
    it 'rejects a numeric-string exp as bad_request instead of 500ing in Time.at' do
      bad = intent_payload.merge(exp: (Time.now.to_i + 600).to_s)
      expect { described_class.verify_intent(raw_jws: craft(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /exp/)
    end

    it 'rejects a string iat as bad_request instead of 500ing in Time.at' do
      bad = intent_payload.merge(iat: 'yesterday')
      expect { described_class.verify_intent(raw_jws: craft(bad), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /iat/)
    end

    it 'rejects an effectively non-expiring mandate (exp beyond the max lifetime)' do
      forever = intent_payload.merge(exp: Time.now.to_i + (400 * 24 * 3600))
      expect { described_class.verify_intent(raw_jws: sign(forever), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /lifetime/)
    end

    it 'still accepts a normal short-lived mandate (well within the max lifetime)' do
      m = described_class.verify_intent(raw_jws: sign(intent_payload), identity: identity)
      expect(m).to be_a(Kiosk::Mandate::IntentMandate)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  # ─── non-positive amounts launder the spending cap ───────────────────
  # A negative cart total slips under the cap (−100000 <= 5000), matches a
  # negative payment, settles, and drives the settlements SUM negative —
  # permanently RAISING the agent's effective cap by that amount. Zero is
  # equally invalid. Every mandate amount MUST be a positive integer of cents.
  describe 'non-positive amounts' do
    it 'rejects a cart with a NEGATIVE total_amount_cents (the launder vector)' do
      neg = cart_payload.merge(total_amount_cents: -100_000)
      expect { described_class.verify_cart(raw_jws: sign(neg), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end

    it 'rejects a cart with a ZERO total_amount_cents' do
      zero = cart_payload.merge(total_amount_cents: 0)
      expect { described_class.verify_cart(raw_jws: sign(zero), identity: identity, intent: intent) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end

    it 'rejects an intent with a NEGATIVE cap_amount_cents' do
      neg = intent_payload.merge(cap_amount_cents: -5000)
      expect { described_class.verify_intent(raw_jws: sign(neg), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end

    it 'rejects an intent with a ZERO cap_amount_cents' do
      zero = intent_payload.merge(cap_amount_cents: 0)
      expect { described_class.verify_intent(raw_jws: sign(zero), identity: identity) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe 'non-positive amounts' do
    it 'rejects a payment with a NEGATIVE amount_cents' do
      neg = payment_payload.merge(amount_cents: -1599)
      expect { described_class.verify_payment(raw_jws: sign(neg), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end

    it 'rejects a payment with a ZERO amount_cents' do
      zero = payment_payload.merge(amount_cents: 0)
      expect { described_class.verify_payment(raw_jws: sign(zero), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /positive/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  # §11.1: `currency` is REQUIRED on the payment, `scope` is optional on the intent.
  describe 'own fields' do
    it 'rejects a payment missing currency (absent)' do
      no_cur = payment_payload.except(:currency)
      expect { described_class.verify_payment(raw_jws: sign(no_cur), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, 'mandate missing required currency field')
    end

    it 'accepts an intent without scope' do
      m = described_class.verify_intent(raw_jws: sign(intent_payload.except(:scope)), identity: identity)
      expect(m.scope).to be_nil
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  # ─── verify_payment ──────────────────────────────────────────────────
  describe '.verify_payment' do
    it 'returns a PaymentMandate for a valid signed JWS bound to the cart' do
      pm = described_class.verify_payment(raw_jws: sign(payment_payload), identity: identity, cart: cart_mandate)
      expect(pm).to be_a(Kiosk::Mandate::PaymentMandate)
      expect(pm.id).to              eq('pay-1')
      expect(pm.cart_mandate_id).to eq('cart-1')
      expect(pm.payment_method).to  eq('pm_card_visa')
      expect(pm.amount_cents).to    eq(1599)
      expect(pm.currency).to        eq('eur')
      expect(pm.issuer).to          eq(issuer)
    end

    it 'rejects a payment not bound to the presented cart (wrong cart_mandate_id)' do
      bad = payment_payload.merge(cart_mandate_id: 'cart-OTHER')
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /bound/)
    end

    it 'rejects a payment whose amount_cents does not match the cart total' do
      bad = payment_payload.merge(amount_cents: 99_999)
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /amount/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_payment' do
    it 'rejects a payment whose amount is under the cart total' do
      bad = payment_payload.merge(amount_cents: 100)
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /amount/)
    end

    it 'rejects a payment with a mismatched currency' do
      bad = payment_payload.merge(currency: 'usd')
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /currency|amount/)
    end

    # SetupIntent model: the assistant authorises but never presents a card —
    # the provider's PSP resolves the principal's on-file card at capture time.
    # payment_method is therefore OPTIONAL in the mandate.
    it 'accepts a payment with a nil/absent payment_method (SetupIntent model: on-file card)' do
      no_pm = payment_payload.except(:payment_method)
      pm = described_class.verify_payment(raw_jws: sign(no_pm), identity: identity, cart: cart_mandate)
      expect(pm).to be_a(Kiosk::Mandate::PaymentMandate)
      expect(pm.payment_method).to be_nil
    end

    it 'accepts a payment with an empty payment_method' do
      empty_pm = payment_payload.merge(payment_method: '')
      pm = described_class.verify_payment(raw_jws: sign(empty_pm), identity: identity, cart: cart_mandate)
      expect(pm.payment_method).to eq('')
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_payment' do
    # amount_cents is a REQUIRED payment field. ABSENT (nil) would
    # nil-coerce to 0 in the amount-match check; against a same-absent (0) cart
    # total it would "match" and persist a 0-cent payment row. Reject on
    # presence, before the .to_i — an absent amount is not a valid payment.
    it 'rejects a payment missing amount_cents (absent, not 0)' do
      no_amount = payment_payload.except(:amount_cents)
      expect { described_class.verify_payment(raw_jws: sign(no_amount), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /amount_cents/)
    end

    it 'applies the shared decode checks (wrong signer rejected)' do
      forged = JWT.encode(payment_payload, OpenSSL::PKey::RSA.generate(2048), 'RS256')
      expect { described_class.verify_payment(raw_jws: forged, identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end

    it 'applies the shared decode checks (expired mandate rejected)' do
      past = payment_payload.merge(exp: (Time.current - 60).to_i)
      expect { described_class.verify_payment(raw_jws: sign(past), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /expired/)
    end
  end
end

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'mandate verifier spec: verifier'

  describe '.verify_payment' do
    it 'applies the shared decode checks (missing exp rejected)' do
      no_exp = payment_payload.except(:exp)
      expect { described_class.verify_payment(raw_jws: sign(no_exp), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden) { |e|
          expect(e.message).to eq('mandate missing a required claim')
          expect(e.hint).to include('exp')
          expect("#{e.message} #{e.hint}").not_to include('Missing required claim')
        }
    end

    it 'applies the shared decode checks (wrong issuer rejected)' do
      bad = payment_payload.merge(iss: 'https://evil.example')
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end

    it 'applies the shared decode checks (principal mismatch rejected)' do
      bad = payment_payload.merge(user_id: 'u-999')
      expect { described_class.verify_payment(raw_jws: sign(bad), identity: identity, cart: cart_mandate) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /principal/)
    end
  end
end
