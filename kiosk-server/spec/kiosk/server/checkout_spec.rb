# frozen_string_literal: true

RSpec.describe Kiosk::Server::Checkout do
  include_context 'with a checkout to pay'

  let(:claims) { JWT.decode(checkout_jwt, CHECKOUT_SIGNING_KEY.public_key, true, algorithms: ['PS256']).first }

  it 'signs PS256 with the key of the JWKS, naming its kid' do
    _, header = JWT.decode(checkout_jwt, CHECKOUT_SIGNING_KEY.public_key, true, algorithms: ['PS256'])
    expect(header).to include('alg' => 'PS256', 'kid' => CHECKOUT_SIGNING_KEY.kid)
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

  it 'answers the claims of a checkout this origin signed for this account' do
    expect(described_class.verify(checkout_jwt, identity:)).to eq(claims)
  end
end
