# frozen_string_literal: true

require 'json_schemer'

RSpec.describe Kiosk::Server::Receipts do
  include_context 'with a checkout to pay'

  let(:checkout_mandate) { Kiosk::Server::MandateVerifier.verify_checkout(sd_jwt: mandates[:checkout], identity:) }
  let(:payment_mandate) do
    Kiosk::Server::MandateVerifier.verify_payment(sd_jwt: mandates[:payment], identity:, checkout: checkout_mandate)
  end
  let(:network_confirmation_id) { '583910485721044' }
  let(:receipts) do
    described_class.issue(checkout: checkout_mandate, payment: payment_mandate, settlement_id: 's-1',
                          psp_reference: 'pi_1', network_confirmation_id:)
  end
  let(:jwks) { Kiosk::Server::Jwks.build(keys: Kiosk.configuration.signing_keys) }

  def decode(receipt) = JWT.decode(receipt, nil, true, algorithms: ['EdDSA']) { Kiosk::Server::Jwks.find(jwks, it['kid']) }

  def claims(receipt) = decode(receipts.fetch(receipt)).first

  def schema(name)
    path = File.expand_path('../../../lib/kiosk/server/schemas/mandates.schema.json', __dir__)
    JSONSchemer.schema(JSON.parse(File.read(path))).ref("#/$defs/#{name}")
  end

  it 'signs both receipts EdDSA with the key of the JWKS, naming its kid' do
    headers = receipts.values.map { decode(it).last }
    expect(headers).to all(include('alg' => 'EdDSA', 'typ' => 'JWT', 'kid' => CHECKOUT_SIGNING_KEY.kid))
  end

  it "names the checkout mandate by its reference and the order by the checkout's first line item" do
    expect(claims(:checkout_receipt)).to include('status' => 'Success', 'iss' => issuer,
                                                 'reference' => Kiosk::Server::SdJwt.digest(mandates[:checkout]),
                                                 'order_id' => 'o-1')
  end

  it 'names the payment mandate by its reference, the settlement and the confirmations' do
    expect(claims(:payment_receipt)).to include('status' => 'Success', 'iss' => issuer,
                                                'reference' => Kiosk::Server::SdJwt.digest(mandates[:payment]),
                                                'payment_id' => 's-1', 'psp_confirmation_id' => 'pi_1',
                                                'network_confirmation_id' => network_confirmation_id)
  end

  it 'answers claims that the published receipt schemas accept' do
    expect(schema('checkoutReceipt').validate(claims(:checkout_receipt)).to_a).to be_empty
    expect(schema('paymentReceipt').validate(claims(:payment_receipt)).to_a).to be_empty
  end

  context 'when the payment provider reports no network id' do
    let(:network_confirmation_id) { nil }

    it 'leaves network_confirmation_id out' do
      expect(claims(:payment_receipt)).not_to have_key('network_confirmation_id')
    end
  end
end
