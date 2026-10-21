# frozen_string_literal: true

RSpec.describe Kiosk::Server::Checkout do
  include_context 'with a checkout to pay'

  let(:claims) { JWT.decode(checkout_jwt, CHECKOUT_SIGNING_KEY.key, true, algorithms: ['EdDSA']).first }

  it 'signs EdDSA with the key of the JWKS, naming its kid' do
    _, header = JWT.decode(checkout_jwt, CHECKOUT_SIGNING_KEY.key, true, algorithms: ['EdDSA'])
    expect(header).to include('alg' => 'EdDSA', 'kid' => CHECKOUT_SIGNING_KEY.kid)
  end

  it 'names the origin, the account, the merchant and what to pay' do
    expect(claims).to include(
      'iss' => issuer, 'sub' => 'u-1', 'currency' => 'eur', 'total_amount_cents' => 450, 'line_items' => line_items,
      'merchant' => { 'id' => issuer, 'name' => 'Demo', 'website' => issuer }
    )
  end

  it 'gives the merchant the issuer for a name when the owner has none' do
    Kiosk.configuration.owner = {}
    expect(claims.dig('merchant', 'name')).to eq(issuer)
  end

  it 'signs the same checkout to other bytes each time, so its hash names one checkout' do
    expect(checkout).not_to eq(checkout)
  end

  # AP2 v0.2: an EdDSA signature is the same for the same claims, so the checkout carries the entropy.
  it 'carries a jti of 128 random bits' do
    expect(claims['jti']).to match(/\A[A-Za-z0-9_-]{22}\z/)
  end

  it 'answers the claims of a checkout this origin signed for this account' do
    expect(described_class.verify(checkout_jwt, identity:)).to eq(claims)
  end

  # Operator key rotation (spec Section 4.4): the checkouts the previous key
  # signed stay payable while that key is still published.
  describe 'across an operator key rotation' do
    let(:signed_before) { checkout_jwt }

    before { signed_before }

    it 'verifies a checkout that the previous key signed' do
      Kiosk.configure do |c|
        c.signing_key          = Kiosk::Server::SigningKey.generate
        c.previous_signing_key = CHECKOUT_SIGNING_KEY.key.public_to_pem
      end
      expect(described_class.verify(signed_before, identity:)).to eq(claims)
    end

    it 'refuses it once the previous key is gone from the JWKS' do
      Kiosk.configure do |c|
        c.signing_key          = Kiosk::Server::SigningKey.generate
        c.previous_signing_key = Kiosk::Server::SigningKey.generate
      end
      expect { described_class.verify(signed_before, identity:) }
        .to raise_error(Kiosk::Server::Errors::Forbidden, 'checkout_jwt signature invalid')
    end
  end
end
