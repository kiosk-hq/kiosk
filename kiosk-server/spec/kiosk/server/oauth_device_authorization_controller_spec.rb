# frozen_string_literal: true

# POST <endpoint>/oauth/device_authorization (RFC 8628 Section 3.1), form-encoded,
# authenticated by a client assertion.
RSpec.describe Kiosk::Server::OauthDeviceAuthorizationController do
  include_context 'with registered clients'

  let(:store)  { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:client) { register_client }

  before { Kiosk.configure { |c| c.device_authorization_store = store } }

  def start(params)
    env = Rack::MockRequest.env_for("#{OauthClients::ISSUER}/kiosk/oauth/device_authorization",
                                    method: 'POST', params: params)
    call_action(described_class, :create, env)
  end

  it "opens a claim ceremony for the client, with the client's key on the row" do
    status, _headers, body = start(assertion_params(client.id))

    expect(status).to eq(200)
    expect(body).to include('user_code' => match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/),
                            'verification_uri' => "#{OauthClients::ISSUER}/kiosk/oauth/device/verify")
    expect(body['verification_uri_complete']).to include(body['user_code'])
    expect(body['expires_in']).to be_positive
    expect(body['interval']).to be_positive
    row = store.lookup_by_device_code_hash(Kiosk::Server::DeviceAuthorization.hash_device_code(body['device_code']))
    expect([row.client_id, row.public_key_pem, row.requested_role]).to eq([client.id, client.public_key_pem, nil])
  end

  it 'answers 401 invalid_client and the Kiosk-Client-Assertion challenge for a missing or refused client assertion' do
    [{}, assertion_params(client.id, key: other_key)].each do |params|
      status, headers, body = start(params)
      expect(status).to eq(401)
      expect(body['error']).to eq('invalid_client')
      expect(headers['WWW-Authenticate']).to eq(%(Kiosk-Client-Assertion realm="#{OauthClients::ISSUER}"))
    end
  end

  it 'refuses a role, also an empty one: the assistant does not choose its role' do
    status, _headers, body = start(assertion_params(client.id).merge('role' => ''))
    expect(status).to eq(400)
    expect(body['error']).to eq('invalid_request')
    expect(body['error_description']).to include('role is not accepted here', 'does not choose its own role')
  end

  it 'ignores a scope: the row carries no requested role' do
    status, _headers, body = start(assertion_params(client.id).merge('scope' => 'owner'))
    expect(status).to eq(200)
    row = store.lookup_by_device_code_hash(Kiosk::Server::DeviceAuthorization.hash_device_code(body['device_code']))
    expect(row.requested_role).to be_nil
  end

  it 'answers 501 module_not_served where the origin serves no binding' do
    Kiosk.configure { |c| c.serve_account_binding = false }
    status, _headers, body = start(assertion_params(client.id))
    expect(status).to eq(501)
    expect(body['code']).to eq('module_not_served')
  end
end
