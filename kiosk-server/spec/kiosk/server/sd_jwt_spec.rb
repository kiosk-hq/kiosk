# frozen_string_literal: true

require 'kiosk/test_helpers/mandate'

RSpec.describe Kiosk::Server::SdJwt do
  # The encoded tokens AP2 v0.2 publishes in docs/ap2/checkout_mandate.md and
  # payment_mandate.md (github.com/google-agentic-commerce/AP2, e1ea56db).
  def vector(name) = File.read(File.expand_path("../../support/standards/ap2-v0.2/#{name}.sd-jwt", __dir__)).strip

  def b64(text) = Base64.urlsafe_encode64(text, padding: false)

  # The agent key an open AP2 mandate names in `cnf`: it signs the closed one.
  def cnf_key(open_token)
    open_mandate = described_class.disclose({ 'delegate_payload' => [{ '...' => digest_of_mandate(open_token) }] },
                                            open_token.split('~')[1..])
    JWT::JWK.import(open_mandate.fetch('delegate_payload').first.dig('cnf', 'jwk').transform_keys(&:to_sym)).verify_key
  end

  def digest_of_mandate(open_token) = JWT.decode(open_token.split('~').first, nil, false).first['delegate_payload'].first['...']

  describe 'against the published AP2 v0.2 tokens' do
    let(:closed_checkout) { vector('closed-checkout') }
    let(:open_checkout)   { vector('open-checkout') }

    it 'verifies the closed checkout mandate with the key of its open mandate, and discloses it' do
      payload, header = described_class.verify(closed_checkout, key: cnf_key(open_checkout), algorithm: 'ES256')
      mandate = payload.fetch('delegate_payload').first

      expect(header).to include('typ' => 'kb+sd-jwt')
      expect(mandate).to include('vct' => 'mandate.checkout.1', 'checkout_hash' => described_class.digest(mandate.fetch('checkout_jwt')))
      expect(payload['sd_hash']).to eq(described_class.digest(open_checkout))
    end

    it 'binds the closed payment mandate to that checkout by transaction_id' do
      checkout, = described_class.verify(closed_checkout, key: cnf_key(open_checkout), algorithm: 'ES256')
      payment, = described_class.verify(vector('closed-payment'), key: cnf_key(vector('open-payment')), algorithm: 'ES256')

      expect(payment.fetch('delegate_payload').first)
        .to include('vct' => 'mandate.payment.1', 'transaction_id' => checkout.fetch('delegate_payload').first.fetch('checkout_hash'),
                    'payment_amount' => { 'amount' => 19_900, 'currency' => 'USD' })
    end

    it 'puts back the disclosures nested in the constraints of an open mandate' do
      jwt, *disclosures = open_checkout.split('~')
      opened = described_class.disclose(JWT.decode(jwt, nil, false).first, disclosures).fetch('delegate_payload').first
      line_items, merchants = opened.fetch('constraints')

      expect(opened['vct']).to eq('mandate.checkout.open.1')
      expect(line_items.dig('items', 0, 'acceptable_items', 0, 'title')).to eq('SuperShoe Limited Edition Gold')
      expect(merchants.dig('allowed', 0, 'id')).to eq('merchant_1')
    end

    it 'refuses a signature by another key' do
      expect { described_class.verify(closed_checkout, key: OpenSSL::PKey::EC.generate('prime256v1'), algorithm: 'ES256') }
        .to raise_error(JWT::VerificationError)
    end
  end

  describe 'the subset a closed mandate uses' do
    let(:key)     { OpenSSL::PKey.generate_key('ED25519') }
    let(:mandate) { Kiosk::TestHelpers::Mandate.sign(key, { vct: 'mandate.payment.1' }) }

    def verify(token) = described_class.verify(token, key: key, algorithm: 'EdDSA')

    it 'answers the payload with the disclosure in place, and the header' do
      payload, header = verify(mandate)

      expect(payload).to eq('delegate_payload' => [{ 'vct' => 'mandate.payment.1' }])
      expect(header['typ']).to eq('dc+sd-jwt')
    end

    it 'refuses a token that carries a key-binding JWT, and a chain of tokens' do
      expect { verify("#{mandate}#{mandate.split('~').first}") }.to raise_error(described_class::Invalid, /no key-binding JWT/)
      expect { verify("#{mandate}~#{mandate}") }.to raise_error(described_class::Invalid, /no empty part/)
    end

    it 'refuses a disclosure that no digest names' do
      extra = b64(JSON.generate(%w[salt name value]))
      expect { verify("#{mandate}#{extra}~") }.to raise_error(described_class::Invalid, /not named by any digest/)
    end

    it 'refuses two disclosures with one digest' do
      disclosure = mandate.split('~')[1]
      expect { verify("#{mandate}#{disclosure}~") }.to raise_error(described_class::Invalid, /same digest/)
    end

    it 'refuses a disclosure that is not base64url JSON' do
      expect { verify("#{mandate.split('~').first}~!!~") }.to raise_error(described_class::Invalid, /base64url-encoded JSON/)
    end

    it 'refuses an _sd_alg other than sha-256' do
      jwt = JWT.encode({ _sd_alg: 'sha-512', delegate_payload: [] }, key, 'EdDSA')
      expect { verify("#{jwt}~") }.to raise_error(described_class::Invalid, /sha-512/)
    end

    it 'refuses an object disclosure under an array digest, and an array disclosure under an object digest' do
      property = b64(JSON.generate(%w[salt name value]))
      element  = b64(JSON.generate(%w[salt value]))
      in_array = JWT.encode({ delegate_payload: [{ '...' => described_class.digest(property) }] }, key, 'EdDSA')
      in_object = JWT.encode({ _sd: [described_class.digest(element)] }, key, 'EdDSA')

      expect { verify("#{in_array}~#{property}~") }.to raise_error(described_class::Invalid, /\[salt, value\]/)
      expect { verify("#{in_object}~#{element}~") }.to raise_error(described_class::Invalid, /\[salt, name, value\]/)
    end

    it 'refuses a disclosed name the object already has' do
      property = b64(JSON.generate(%w[salt vct other]))
      jwt = JWT.encode({ vct: 'mandate.payment.1', _sd: [described_class.digest(property)] }, key, 'EdDSA')
      expect { verify("#{jwt}~#{property}~") }.to raise_error(described_class::Invalid, /already in the object/)
    end

    it 'leaves out an array digest with no disclosure, a decoy' do
      jwt = JWT.encode({ delegate_payload: [{ '...' => described_class.digest('decoy') }, 1] }, key, 'EdDSA')
      expect(verify("#{jwt}~").first).to eq('delegate_payload' => [1])
    end
  end
end
