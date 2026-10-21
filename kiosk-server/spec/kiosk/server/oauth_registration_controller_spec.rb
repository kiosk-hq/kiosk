# frozen_string_literal: true

require 'kiosk/pow/equihash'
require 'kiosk/reputation'

# POST <endpoint>/oauth/register (RFC 7591), called as a Rack app.
RSpec.describe Kiosk::Server::OauthRegistrationController do
  include_context 'with registered clients'

  def register(raw)
    env = Rack::MockRequest.env_for("#{OauthClients::ISSUER}/kiosk/oauth/register", method: 'POST', input: raw,
                                                                                    'CONTENT_TYPE' => 'application/json')
    call_action(described_class, :create, env)
  end

  let(:body) { JSON.generate(jwks: jwks_of(agent_key), token_endpoint_auth_method: 'private_key_jwt') }

  it 'answers 201 with the client information, which no cache keeps' do
    status, headers, info = register(body)
    expect(status).to eq(201)
    expect(headers['Cache-Control']).to eq('no-store')
    expect(info).to include('client_id' => be_a(String), 'token_endpoint_auth_method' => 'private_key_jwt',
                            'dpop_bound_access_tokens' => true)
    expect(info['jwks']).to eq(jwks_of(agent_key))
  end

  it 'answers the same client_id for the same key' do
    first = register(body).last['client_id']
    expect(register(body).last['client_id']).to eq(first)
  end

  it 'answers 400 invalid_client_metadata for a body that is not JSON, or has no key' do
    ['', 'not json', '[]', '{}'].each do |raw|
      status, headers, error = register(raw)
      expect(status).to eq(400)
      expect(headers['Cache-Control']).to eq('no-store')
      expect(error).to include('error' => 'invalid_client_metadata', 'error_description' => be_a(String))
    end
  end

  describe 'the toll' do
    before do
      Kiosk::Reputation::Backends.register('equihash', Kiosk::Pow::Equihash)
      allow(Kiosk::Pow::Equihash).to receive(:params).and_return({ n: 8, k: 1 })
      Kiosk.configure do |c|
        c.registration_pow_count = 1
        c.pow_secret             = 'registration-pow-secret-at-least-32-bytes'
      end
    end

    after { Kiosk::Reputation::Backends.reset! }

    it 'answers the problem document 402 pow_required with WWW-Authenticate: Kiosk-PoW, and registers nothing' do
      status, headers, problem = register(body)

      expect(status).to eq(402)
      expect(headers['WWW-Authenticate']).to eq(%(Kiosk-PoW realm="#{OauthClients::ISSUER}"))
      expect(headers['Content-Type']).to include('application/problem+json')
      expect(problem).to include('type' => 'https://kiosk.tech/problems/pow_required', 'status' => 402,
                                 'code' => 'pow_required', 'challenges' => be_an(Array))
      # A challenge is single-use and bound to this request: a cache must not keep it.
      expect(headers['Cache-Control']).to eq('no-store')
      expect(Kiosk::Server::Client.with_key(agent_key.public_key)).to be_nil
    end
  end
end
