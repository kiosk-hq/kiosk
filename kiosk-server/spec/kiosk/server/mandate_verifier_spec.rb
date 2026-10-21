# frozen_string_literal: true

RSpec.describe Kiosk::Server::MandateVerifier do
  include_context 'with a checkout to pay'

  def verify_checkout(sd_jwt = mandates[:checkout]) = described_class.verify_checkout(sd_jwt:, identity:)

  def verify_payment(sd_jwt = mandates[:payment]) = described_class.verify_payment(sd_jwt:, identity:, checkout: verify_checkout)

  def refused(message, status = Kiosk::Server::Errors::Forbidden)
    raise_error(status) { |e| expect(e.message).to match(message) }
  end

  describe '.verify_checkout' do
    it 'answers the checkout mandate, its values taken from the checkout this origin signed' do
      expect(verify_checkout).to have_attributes(
        reference: Kiosk::Server::SdJwt.digest(mandates[:checkout]),
        checkout_hash: Kiosk::Server::SdJwt.digest(checkout_jwt),
        user_id: 'u-1', agent_id: 'agent-1', issuer: issuer, line_items: line_items,
        total_amount_cents: 450, currency: 'eur', sd_jwt: mandates[:checkout]
      )
    end

    it 'takes the currency in lower case, the spelling the spending cap counts' do
      checkout_jwt.replace(checkout(currency: 'EUR'))
      expect(verify_checkout.currency).to eq('eur')
    end

    context 'when the agent key is a P-256 key and the operator accepts ES256' do
      let(:agent_key) { Kiosk::TestHelpers::Dpop.generate_key('ES256') }

      before { Kiosk.configure { |c| c.assistant_algorithms = %w[EdDSA ES256] } }

      it 'verifies the mandates the key signs ES256' do
        expect(JWT.decode(mandates[:checkout].split('~').first, nil, false).last['alg']).to eq('ES256')
        expect(verify_checkout.checkout_hash).to eq(Kiosk::Server::SdJwt.digest(checkout_jwt))
      end
    end

    it 'refuses a mandate signed by any key but the agent key' do
      forged = resign(mandates[:checkout], key: OpenSSL::PKey.generate_key('ED25519'))
      expect { verify_checkout(forged) }.to refused(/mandate signature invalid/)
    end

    it 'refuses an SD-JWT whose header typ is not dc+sd-jwt' do
      jwt, disclosure = mandates[:checkout].split('~')
      untyped = JWT.encode(JWT.decode(jwt, nil, false).first, agent_key, 'EdDSA')
      expect { verify_checkout("#{untyped}~#{disclosure}~") }.to refused(/typ is not dc\+sd-jwt/)
    end

    it 'refuses a token that is not an SD-JWT, with the reason in the hint' do
      expect { verify_checkout(JWT.encode({ a: 1 }, agent_key, 'EdDSA')) }
        .to raise_error(Kiosk::Server::Errors::Forbidden) { |e| expect(e.hint).to include('ends with "~"') }
    end

    it 'refuses a signed payload that carries no mandate' do
      empty = "#{JWT.encode({ _sd_alg: 'sha-256' }, agent_key, 'EdDSA', { typ: 'dc+sd-jwt' })}~"
      expect { verify_checkout(empty) }.to refused(/carries no mandate/)
    end

    it 'refuses an open mandate, and a payment mandate in the checkout place' do
      expect { verify_checkout(resign(mandates[:checkout], vct: 'mandate.checkout.open.1')) }.to refused(/vct is not mandate.checkout.1/)
      expect { verify_checkout(mandates[:payment]) }.to refused(/vct is not mandate.checkout.1/)
    end

    it 'refuses a mandate with no checkout_jwt, or a checkout_hash of other bytes' do
      expect { verify_checkout(resign(mandates[:checkout], checkout_jwt: nil)) }.to refused(/no checkout_jwt/)
      expect { verify_checkout(resign(mandates[:checkout], checkout_hash: Kiosk::Server::SdJwt.digest('x'))) }
        .to refused(/checkout_hash is not the hash/)
    end

    describe 'the checkout it binds' do
      def bound(jwt) = resign(mandates[:checkout], checkout_jwt: jwt, checkout_hash: Kiosk::Server::SdJwt.digest(jwt))

      it "refuses a checkout that another key signs under this key's kid, EdDSA or RS256" do
        claims = JWT.decode(checkout_jwt, nil, false).first.merge('total_amount_cents' => 1)
        header = { kid: CHECKOUT_SIGNING_KEY.kid, typ: 'JWT' }
        expect { verify_checkout(bound(JWT.encode(claims, OpenSSL::PKey.generate_key('ED25519'), 'EdDSA', header))) }
          .to refused(/checkout_jwt signature invalid/)
        expect { verify_checkout(bound(JWT.encode(claims, OpenSSL::PKey::RSA.generate(2048), 'RS256', header))) }
          .to refused(/checkout_jwt signature invalid/)
      end

      it 'refuses a checkout another origin of this deployment signed' do
        other = Kiosk.with_issuer('https://other.example') { checkout }
        expect { verify_checkout(bound(other)) }.to refused(/not from this origin/)
      end

      it 'refuses a checkout signed for another account' do
        expect { verify_checkout(bound(checkout(user_id: 'u-2'))) }.to refused(/for another account/)
      end
    end

    describe 'the lifetime' do
      it 'refuses a mandate whose exp has passed' do
        expect { verify_checkout(resign(mandates[:checkout], exp: Time.now.to_i - 1)) }.to refused(/mandate expired/)
      end

      it 'answers 400 for an exp or iat that is not an integer, before Time.at' do
        expect { verify_checkout(resign(mandates[:checkout], exp: (Time.now.to_i + 60).to_s)) }
          .to refused(/exp must be an integer/, Kiosk::Server::Errors::BadRequest)
        expect { verify_checkout(resign(mandates[:checkout], iat: nil)) }
          .to refused(/iat must be an integer/, Kiosk::Server::Errors::BadRequest)
      end

      it 'answers 400 for an exp beyond the maximum lifetime, and accepts one within it' do
        too_long = Time.now.to_i + described_class::MAX_MANDATE_LIFETIME_SECONDS + 60
        expect { verify_checkout(resign(mandates[:checkout], exp: too_long)) }
          .to refused(/lifetime exceeds/, Kiosk::Server::Errors::BadRequest)
        expect(verify_checkout(resign(mandates[:checkout], exp: Time.now.to_i + 3600))).to be_a(Kiosk::Mandate::CheckoutMandate)
      end
    end

    it 'refuses a mandate of an agent revoked since it authenticated' do
      allow(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new).to receive(:agent_payment_key)
        .and_raise(Kiosk::AgentIdentityProviders::InvalidToken)
      expect { verify_checkout }.to refused(/no registered payment key/)
    end
  end

  describe '.verify_payment' do
    it 'answers the payment mandate for that checkout' do
      expect(verify_payment).to have_attributes(
        reference: Kiosk::Server::SdJwt.digest(mandates[:payment]), transaction_id: Kiosk::Server::SdJwt.digest(checkout_jwt),
        payment_instrument: 'on_file', amount_cents: 450, currency: 'eur', user_id: 'u-1', agent_id: 'agent-1'
      )
    end

    it 'refuses a payment for another checkout' do
      expect { verify_payment(resign(mandates[:payment], transaction_id: Kiosk::Server::SdJwt.digest('other'))) }
        .to refused(/not bound to the checkout/)
    end

    it 'refuses a payee that is not this origin, or none' do
      expect { verify_payment(resign(mandates[:payment], payee: { id: 'https://other.example', name: 'Other' })) }
        .to refused(/payee is not this origin/)
      expect { verify_payment(resign(mandates[:payment], payee: nil)) }.to refused(/payee is not this origin/)
    end

    it 'refuses an amount or a currency other than the checkout, and an amount in a string' do
      [{ amount: 449, currency: 'eur' }, { amount: 450, currency: 'usd' }, { amount: '450', currency: 'eur' }, nil].each do |amount|
        expect { verify_payment(resign(mandates[:payment], payment_amount: amount)) }.to refused(%r{amount/currency does not match})
      end
    end

    it 'compares the currency as a code' do
      expect(verify_payment(resign(mandates[:payment], payment_amount: { amount: 450, currency: 'EUR' })).currency).to eq('eur')
    end

    it 'refuses a payment with no instrument id or type' do
      [nil, { id: '', type: 'card' }, { id: 'on_file' }].each do |instrument|
        expect { verify_payment(resign(mandates[:payment], payment_instrument: instrument)) }.to refused(/no payment_instrument/)
      end
    end

    it 'refuses a checkout mandate in the payment place' do
      expect { verify_payment(mandates[:checkout]) }.to refused(/vct is not mandate.payment.1/)
    end
  end
end
