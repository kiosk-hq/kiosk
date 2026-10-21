# frozen_string_literal: true

require 'base64'
require 'kiosk/test_helpers/assistant'

# Records the requests an origin receives, and answers a toll first.
module AssistantRequests
  def requests_to(method, path)
    sent = []
    [stub_request(method, /\A#{origin}#{path}/).with { sent << it }, sent]
  end

  def toll_then(stub, answer)
    calls = 0
    stub.to_return { (calls += 1) == 1 ? problem_return('pow_required', status: 402, challenges: [toll]) : answer }
  end
end

RSpec.shared_context 'with an assistant and an origin' do
  include AssistantRequests

  subject(:assistant) { described_class.new(base_url: origin) }

  let(:origin)     { 'http://kiosk.example.com' }
  let(:key)        { OpenSSL::PKey::RSA.generate(2048) }
  let(:principal)  { described_class::Principal.new(agent_id: 'a1', user_id: 'u1', token: 'tok', rsa_key: key) }
  let(:registered) { json_return(201, 'agent_id' => 'a1', 'user_id' => 'u1', 'access_token' => 'tok') }
  let(:toll) do
    { 'id' => 'c1', 'alg' => 'equihash', 'params' => { 'n' => 8, 'k' => 1 },
      'salt' => Base64.strict_encode64('kat'), 'exp' => 9_999_999_999, 'sig' => 'x' }
  end

  before do
    stub_request(:get, %r{/kiosk/auth/challenge}).to_return(json_return(200, 'challenge' => 'nonce-1'))
  end
end

RSpec.describe Kiosk::TestHelpers::Assistant do
  describe '#register!' do
    include_context 'with an assistant and an origin'

    it 'proves possession of a fresh key, origin-bound, and answers the principal' do
      stub, sent = requests_to(:post, '/kiosk/auth/register')
      stub.to_return(registered)

      registered_principal = assistant.register!

      body = JSON.parse(sent.first.body)
      claims, = JWT.decode(body['signed'], registered_principal.rsa_key.public_key, true, algorithm: 'RS256')
      expect(body.keys).to contain_exactly('public_key', 'signed')
      expect(claims).to include('aud' => origin, 'nonce' => 'nonce-1')
      expect(registered_principal).to have_attributes(agent_id: 'a1', user_id: 'u1', token: 'tok')
    end

    it 'pays a registration toll with the proofs in the Kiosk-PoW header and the same body' do
      stub, sent = requests_to(:post, '/kiosk/auth/register')
      toll_then(stub, registered)

      assistant.register!

      expect(sent.map(&:body).uniq.size).to eq(1)
      expect(sent.first.headers).not_to have_key('Kiosk-Pow')
      expect(JSON.parse(sent.last.headers['Kiosk-Pow']).first).to include('challenge' => toll, 'nonce' => include('indices'))
    end

    it 'raises when the origin does not register' do
      stub_request(:post, "#{origin}/kiosk/auth/register").to_return(problem_return('bad_request', status: 422))

      expect { assistant.register! }.to raise_error(described_class::RegistrationError, /expected 201, got 422/)
    end
  end

  describe '#register_raw' do
    include_context 'with an assistant and an origin'

    it 'sends no proof when told to skip, and a verbatim one when given a string' do
      stub, sent = requests_to(:post, '/kiosk/auth/register')
      stub.to_return(problem_return('pow_required', status: 402, challenges: [toll]))

      expect(assistant.register_raw(pow: :skip).status).to eq(402)
      assistant.register_raw(pow: 'not-a-proof')

      expect(sent.map { it.headers['Kiosk-Pow'] }).to eq([nil, 'not-a-proof'])
    end

    it 'sends the role an assistant has no right to choose' do
      stub, sent = requests_to(:post, '/kiosk/auth/register')
      stub.to_return(registered)

      assistant.register_raw(wire_role: 'admin')

      expect(JSON.parse(sent.first.body)['role']).to eq('admin')
    end
  end

  describe '#pay' do
    include_context 'with an assistant and an origin'

    let(:checkout_jwt) do
      JWT.encode({ iss: origin, sub: 'u1', merchant: { id: origin, name: 'Shop' }, currency: 'eur',
                   total_amount_cents: 100, line_items: [{ order_id: 'o1' }] }, OpenSSL::PKey::RSA.generate(2048), 'PS256')
    end

    def sent_mandates(sent) = JSON.parse(sent.first.body).transform_values { Kiosk::TestHelpers::Mandate.content(it) }

    it "signs the two closed mandates with the principal's key and binds the payment to the checkout" do
      stub, sent = requests_to(:post, '/kiosk/pay')
      stub.to_return(json_return(200, 'settlement_id' => 's1'))

      assistant.pay(principal, checkout_jwt)

      body = JSON.parse(sent.first.body)
      body.each_value { expect(JWT.decode(it.split('~').first, key.public_key, true, algorithm: 'RS256').last['typ']).to eq('dc+sd-jwt') }
      checkout, payment = sent_mandates(sent).values_at('checkout_mandate', 'payment_mandate')
      expect(checkout).to include('vct' => 'mandate.checkout.1', 'checkout_jwt' => checkout_jwt,
                                  'checkout_hash' => Kiosk::TestHelpers::Mandate.digest(checkout_jwt))
      expect(payment).to include('vct' => 'mandate.payment.1', 'transaction_id' => checkout['checkout_hash'],
                                 'payee' => { 'id' => origin, 'name' => 'Shop' },
                                 'payment_amount' => { 'amount' => 100, 'currency' => 'eur' },
                                 'payment_instrument' => { 'id' => 'on_file', 'type' => 'card' })
    end

    it 're-sends the same signed mandates when it pays a toll' do
      stub, sent = requests_to(:post, '/kiosk/pay')
      toll_then(stub, json_return(200, 'settlement_id' => 's1'))

      assistant.pay(principal, checkout_jwt)

      expect(sent.map(&:body).uniq.size).to eq(1)
    end
  end

  describe '#pay when payment setup is required' do
    include_context 'with an assistant and an origin'

    let(:checkout_jwt) do
      JWT.encode({ iss: origin, sub: 'u1', merchant: { id: origin, name: 'Shop' }, currency: 'eur',
                   total_amount_cents: 100, line_items: [{ order_id: 'o1' }] }, OpenSSL::PKey::RSA.generate(2048), 'PS256')
    end

    it 'calls payment_setup on payment_setup_required and sends the same mandates once more' do
      stub, sent = requests_to(:post, '/kiosk/pay')
      stub.to_return(problem_return('payment_setup_required', status: 402), json_return(200, 'settlement_id' => 's1'))
      setup = stub_request(:post, "#{origin}/kiosk/payment_setup").to_return(json_return(200, 'status' => 'ready'))

      expect(assistant.pay(principal, checkout_jwt)).to have_attributes(status: 200)
      expect(setup).to have_been_requested.once
      expect(sent.map(&:body).uniq.size).to eq(1)
      expect(sent.size).to eq(2)
    end

    it 'answers the second refusal when payment setup is still not done' do
      stub, sent = requests_to(:post, '/kiosk/pay')
      stub.to_return(problem_return('payment_setup_required', status: 402))
      stub_request(:post, "#{origin}/kiosk/payment_setup")
        .to_return(json_return(200, 'status' => 'setup_required', 'setup_url' => 'https://pay.example/setup'))

      expect(assistant.pay(principal, checkout_jwt)).to have_attributes(status: 402)
      expect(sent.size).to eq(2)
    end
  end

  describe 'queries and actions' do
    include_context 'with an assistant and an origin'

    it 'queries with the arguments on the query string' do
      stub, sent = requests_to(:get, '/kiosk/my_orders')
      stub.to_return(json_return(200, [{ 'id' => 'r1' }]))

      response = assistant.query(principal, name: 'my_orders', restaurant: 'Foo', limit: 5)

      expect(response.body).to eq([{ 'id' => 'r1' }])
      expect(URI.decode_www_form(sent.first.uri.query).to_h).to eq('restaurant' => 'Foo', 'limit' => '5')
      expect(sent.first.headers['Authorization']).to eq('Bearer tok')
    end

    it 'runs an action with the arguments as the whole body, and extra headers on top' do
      stub, sent = requests_to(:post, '/kiosk/place_order')
      stub.to_return(json_return(200, 'order_id' => 'o1'))

      assistant.run(principal, name: 'place_order', headers: { 'Kiosk-Timezone' => 'Europe/Dublin' }, sku: 'SK-1')

      expect(JSON.parse(sent.first.body)).to eq('sku' => 'SK-1')
      expect(sent.first.headers['Kiosk-Timezone']).to eq('Europe/Dublin')
    end

    it 'answers the response headers' do
      stub_request(:get, "#{origin}/kiosk/search").to_return(status: 200, body: '[]', headers: { 'X-Total-Count' => '42' })

      expect(assistant.query(principal, name: 'search')['x-total-count']).to eq('42')
    end
  end

  describe 'proof-of-work tolls' do
    include_context 'with an assistant and an origin'

    it 'pays a toll once and says how many proofs it cost' do
      stub, sent = requests_to(:get, '/kiosk/catalog')
      toll_then(stub, json_return(200, []))

      response = assistant.query(principal, name: 'catalog', city: 'Lisbon')

      expect(response).to have_attributes(status: 200, proofs: 1, pow_retried?: true)
      expect(sent.map(&:uri).uniq.size).to eq(1)
    end

    it 'pays a re-demanded toll only once' do
      stub, sent = requests_to(:get, '/kiosk/catalog')
      stub.to_return { problem_return('pow_required', status: 402, challenges: [toll]) }

      expect(assistant.query(principal, name: 'catalog')).to have_attributes(status: 402, pow_retried?: true)
      expect(sent.size).to eq(2)
    end

    it 'leaves a 402 without challenges alone' do
      stub, sent = requests_to(:post, '/kiosk/reschedule')
      stub.to_return(problem_return('payment_setup_required', status: 402))

      expect(assistant.run(principal, name: 'reschedule')).to have_attributes(status: 402, pow_retried?: false)
      expect(sent.size).to eq(1)
    end
  end

  describe 'attestation and account binding' do
    include_context 'with an assistant and an origin'

    it 'submits an attestation' do
      stub, sent = requests_to(:post, '/kiosk/agents/kyc')
      stub.to_return(json_return(200, 'attributes' => {}))

      assistant.kyc(principal, attestation_jws: 'a.b.c')

      expect(JSON.parse(sent.first.body)).to eq('kyc_jws' => 'a.b.c')
      expect(sent.first.headers['Authorization']).to eq('Bearer tok')
    end

    it 'opens the account-binding ceremony as a form, with whatever else the caller sends' do
      stub_request(:post, 'https://kiosk.example.com/kiosk/oauth/device_authorization')
        .with(body: { 'client_id' => 'cli', 'public_key' => 'PEM', 'role' => 'owner' })
        .to_return(json_return(200, 'user_code' => 'ABCD'))

      response = described_class.new(base_url: 'https://kiosk.example.com')
                                .device_authorization(client_id: 'cli', public_key: 'PEM', role: 'owner')

      expect(response.body['user_code']).to eq('ABCD')
    end
  end
end
