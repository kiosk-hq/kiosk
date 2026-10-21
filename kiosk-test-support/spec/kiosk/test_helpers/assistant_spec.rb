# frozen_string_literal: true

require 'base64'
require 'kiosk/test_helpers/assistant'

# Records the requests an origin receives, and answers a toll first.
module AssistantRequests
  def requests_to(method, path)
    sent = []
    [stub_request(method, /\A#{origin}#{path}/).with { sent << it }, sent]
  end

  def new_token = JWT.encode({ sub: 'u1', agent_id: 'a1' }, nil, 'none')

  # The token endpoint's answer: a token for account u1.
  def issued = json_return(200, 'access_token' => new_token)

  def toll_then(stub, answer)
    calls = 0
    stub.to_return { (calls += 1) == 1 ? problem_return('pow_required', status: 402, challenges: [toll]) : answer }
  end
end

RSpec.shared_context 'with an assistant and an origin' do
  include AssistantRequests

  subject(:assistant) { described_class.new(base_url: origin) }

  let(:origin)     { 'http://kiosk.example.com' }
  let(:key)        { OpenSSL::PKey.generate_key('ED25519') }
  let(:principal)  { described_class::Principal.new(agent_id: 'a1', user_id: 'u1', token: 'tok', key: key) }
  let(:registered) { json_return(201, 'client_id' => 'a1') }
  let(:toll) do
    { 'id' => 'c1', 'alg' => 'equihash', 'params' => { 'n' => 8, 'k' => 1 },
      'salt' => Base64.strict_encode64('kat'), 'exp' => 9_999_999_999, 'sig' => 'x' }
  end

  # The client assertion of a form or JSON body, verified with `with`.
  def assertion(body, with: key)
    expect(body['client_assertion_type']).to eq(described_class::ASSERTION_TYPE)
    JWT.decode(body['client_assertion'], with, true, algorithm: 'EdDSA').first
  end
end

RSpec.describe Kiosk::TestHelpers::Assistant do
  describe '#register!' do
    include_context 'with an assistant and an origin'

    it 'registers the public JWK of a fresh key, then asks for a token with a client assertion and a DPoP proof' do
      stub, registrations = requests_to(:post, '/kiosk/oauth/register')
      stub.to_return(registered)
      stub, tokens = requests_to(:post, '/kiosk/oauth/token')
      stub.to_return(issued)

      registered_principal = assistant.register!

      jwk = JSON.parse(registrations.first.body).dig('jwks', 'keys', 0)
      expect(jwk).to eq(Kiosk::TestHelpers::Dpop.jwk(registered_principal.key).transform_keys(&:to_s))
      form = URI.decode_www_form(tokens.first.body).to_h
      expect(form['grant_type']).to eq('client_credentials')
      expect(assertion(form, with: registered_principal.key)).to include('iss' => 'a1', 'sub' => 'a1', 'aud' => origin)
      proof, = JWT.decode(tokens.first.headers['Dpop'], registered_principal.key, true, algorithm: 'EdDSA')
      expect(proof).to include('htm' => 'POST', 'htu' => "#{origin}/kiosk/oauth/token")
      expect(proof).not_to have_key('ath')
      expect(tokens.first.headers).not_to have_key('Authorization')
      expect(registered_principal).to have_attributes(agent_id: 'a1', user_id: 'u1')
    end

    it 'pays a registration toll with the proofs in the Kiosk-PoW header and the same body' do
      stub, sent = requests_to(:post, '/kiosk/oauth/register')
      toll_then(stub, registered)
      stub_request(:post, "#{origin}/kiosk/oauth/token").to_return(issued)

      assistant.register!

      expect(sent.map(&:body).uniq.size).to eq(1)
      expect(sent.first.headers).not_to have_key('Kiosk-Pow')
      expect(JSON.parse(sent.last.headers['Kiosk-Pow']).first).to include('challenge' => toll, 'nonce' => include('indices'))
    end

    it 'raises when the origin does not register' do
      stub_request(:post, "#{origin}/kiosk/oauth/register").to_return(json_return(400, 'error' => 'invalid_client_metadata'))

      expect { assistant.register! }.to raise_error(described_class::RegistrationError, /expected 201, got 400/)
    end

    it 'raises when the origin issues no token' do
      stub_request(:post, "#{origin}/kiosk/oauth/register").to_return(registered)
      stub_request(:post, "#{origin}/kiosk/oauth/token").to_return(json_return(401, 'error' => 'invalid_client'))

      expect { assistant.register! }.to raise_error(described_class::RegistrationError, /expected 200, got 401/)
    end
  end

  describe '#register_raw' do
    include_context 'with an assistant and an origin'

    it 'sends no proof when told to skip, and a verbatim one when given a string' do
      stub, sent = requests_to(:post, '/kiosk/oauth/register')
      stub.to_return(problem_return('pow_required', status: 402, challenges: [toll]))

      expect(assistant.register_raw(pow: :skip).status).to eq(402)
      assistant.register_raw(pow: 'not-a-proof')

      expect(sent.map { it.headers['Kiosk-Pow'] }).to eq([nil, 'not-a-proof'])
    end

    it 'sends the role an assistant has no right to choose' do
      stub, sent = requests_to(:post, '/kiosk/oauth/register')
      stub.to_return(registered)

      assistant.register_raw(wire_role: 'admin')

      expect(JSON.parse(sent.first.body)['role']).to eq('admin')
    end
  end

  describe '#pay' do
    include_context 'with an assistant and an origin'

    let(:checkout_jwt) do
      JWT.encode({ iss: origin, sub: 'u1', merchant: { id: origin, name: 'Shop' }, currency: 'eur',
                   total_amount_cents: 100, line_items: [{ order_id: 'o1' }] }, OpenSSL::PKey.generate_key('ED25519'), 'EdDSA')
    end

    def sent_mandates(sent) = JSON.parse(sent.first.body).transform_values { Kiosk::TestHelpers::Mandate.content(it) }

    it "signs the two closed mandates with the principal's key and binds the payment to the checkout" do
      stub, sent = requests_to(:post, '/kiosk/pay')
      stub.to_return(json_return(200, 'settlement_id' => 's1'))

      assistant.pay(principal, checkout_jwt)

      body = JSON.parse(sent.first.body)
      body.each_value { expect(JWT.decode(it.split('~').first, key, true, algorithm: 'EdDSA').last['typ']).to eq('dc+sd-jwt') }
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
                   total_amount_cents: 100, line_items: [{ order_id: 'o1' }] }, OpenSSL::PKey.generate_key('ED25519'), 'EdDSA')
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
      expect(sent.first.headers['Authorization']).to eq('DPoP tok')
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
      expect(sent.first.headers['Authorization']).to eq('DPoP tok')
    end

    it 'rotates to a new key: the old key names the new one, the new key signs its own assertion' do
      stub, sent = requests_to(:post, '/kiosk/auth/rotate')
      stub.to_return(json_return(200, 'client_id' => 'a1'))
      stub_request(:post, "#{origin}/kiosk/oauth/token").to_return(issued)
      new_key = OpenSSL::PKey.generate_key('ED25519')

      rotated = assistant.rotate(principal, new_key:)

      body = JSON.parse(sent.first.body)
      old_claims = assertion(body)
      new_claims, = JWT.decode(body['new_client_assertion'], new_key, true, algorithm: 'EdDSA')
      expect(old_claims['new_key']).to eq(Kiosk::TestHelpers::Dpop.thumbprint(new_key))
      expect(new_claims).to include('sub' => 'a1')
      expect(new_claims).not_to have_key('new_key')
      expect(body.dig('jwks', 'keys', 0, 'n')).to eq(Kiosk::TestHelpers::Dpop.jwk(new_key)[:n])
      expect(rotated).to have_attributes(agent_id: 'a1', key: new_key, token: new_token)
    end

    it 'redeems a link code with a client assertion' do
      stub, sent = requests_to(:post, '/kiosk/auth/claim')
      stub.to_return(status: 204)

      expect(assistant.claim('LINK-1', principal).status).to eq(204)
      body = JSON.parse(sent.first.body)
      expect(body['code']).to eq('LINK-1')
      expect(assertion(body)).to include('sub' => 'a1', 'aud' => origin)
    end

    it 'opens the account-binding ceremony as a form with a client assertion, and whatever else the caller sends' do
      stub, sent = requests_to(:post, '/kiosk/oauth/device_authorization')
      stub.to_return(json_return(200, 'user_code' => 'ABCD'))

      response = assistant.device_authorization(principal, role: 'owner')

      form = URI.decode_www_form(sent.first.body).to_h
      expect(form['role']).to eq('owner')
      expect(assertion(form)).to include('sub' => 'a1')
      expect(response.body['user_code']).to eq('ABCD')
    end

    it 'polls the device grant with a client assertion and a DPoP proof that carries no token' do
      stub, sent = requests_to(:post, '/kiosk/oauth/token')
      stub.to_return(json_return(400, 'error' => 'authorization_pending'))

      assistant.device_token('d1', principal)

      form = URI.decode_www_form(sent.first.body).to_h
      expect(form).to include('grant_type' => described_class::DEVICE_CODE, 'device_code' => 'd1')
      expect(assertion(form)).to include('sub' => 'a1')
      expect(JWT.decode(sent.first.headers['Dpop'], key, true, algorithm: 'EdDSA').first).not_to have_key('ath')
    end
  end
end
