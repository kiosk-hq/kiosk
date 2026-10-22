# frozen_string_literal: true

require 'kiosk/pow/equihash'
require 'kiosk/reputation'

# POST <endpoint>/oauth/token: a client assertion (RFC 7523) and a DPoP proof
# (RFC 9449) for the client_credentials grant and the device-code grant.
RSpec.describe Kiosk::Server::OauthTokenController do
  include_context 'with registered clients'

  let(:client) { register_client }
  let(:store)  { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }

  before do
    Kiosk.configure { |c| c.device_authorization_store = store }
    Kiosk::Server::DeviceCodeGrant.reset_poll_registry!
  end

  def claims_of(token) = JWT.decode(token, nil, false).first

  def expect_oauth_error(response, error, status: 400)
    code, headers, body = response
    expect(code).to eq(status)
    expect(headers['Cache-Control']).to eq('no-store')
    expect(body).to include('error' => error, 'error_description' => be_a(String))
  end

  describe 'grant_type=client_credentials' do
    it 'answers a DPoP token bound to the registered key, which no cache keeps' do
      status, headers, body = client_credentials(client.id)

      expect(status).to eq(200)
      expect(headers['Cache-Control']).to eq('no-store')
      expect(body).to include('token_type' => 'DPoP', 'expires_in' => 3600, 'scope' => 'customer')
      expect(claims_of(body['access_token'])).to include('sub' => client.user_id, 'agent_id' => client.id,
                                                         'role' => 'customer', 'cnf' => { 'jkt' => agent_jkt })
    end

    it 'ignores a requested scope and grants the role of the client' do
      params = { 'grant_type' => 'client_credentials', 'scope' => 'owner', **assertion_params(client.id) }
      status, _headers, body = token_request(params)

      expect([status, body['scope'], claims_of(body['access_token'])['role']]).to eq([200, 'customer', 'customer'])
    end

    it 'leaves out scope for a client with no role' do
      Kiosk.configure do |c|
        c.roles = []
        c.registration_role = nil
      end
      expect(client_credentials(client.id).last).not_to have_key('scope')
    end

    it 'answers 401 invalid_client for a refused client assertion, and says what to fix' do
      response = client_credentials(client.id, key: other_key)
      expect_oauth_error(response, 'invalid_client', status: 401)
      expect(response.last['error_description']).to include('signature invalid', 'registered key')
    end

    it 'answers invalid_client for an unlinked client' do
      ActiveRecord::Base.connection.exec_query(
        %(UPDATE "#{OauthClients::SCHEMA}".agents SET revoked_at = now() WHERE id = $1), 'spec', [client.id]
      )
      expect_oauth_error(client_credentials(client.id), 'invalid_client', status: 401)
    end

    it 'answers invalid_dpop_proof with no proof, a proof of another key, or a proof for another URL' do
      params = { 'grant_type' => 'client_credentials' }
      expect_oauth_error(token_request(params.merge(assertion_params(client.id)), dpop: nil), 'invalid_dpop_proof')
      expect_oauth_error(token_request(params.merge(assertion_params(client.id)),
                                       dpop: token_request_proof(token_url, key: other_key)), 'invalid_dpop_proof')
      expect_oauth_error(token_request(params.merge(assertion_params(client.id)),
                                       dpop: token_request_proof("#{OauthClients::ISSUER}/kiosk/oauth/other")),
                         'invalid_dpop_proof')
    end
  end

  it 'answers invalid_request with no grant_type, and unsupported_grant_type for another grant' do
    expect_oauth_error(token_request({}), 'invalid_request')
    expect_oauth_error(token_request({ 'grant_type' => 'refresh_token' }), 'unsupported_grant_type')
  end

  describe 'grant_type=urn:ietf:params:oauth:grant-type:device_code' do
    let(:grant)  { Kiosk::Server::DeviceCodeGrant::GRANT_TYPE }
    let(:holder) { holder! }
    let(:start)  { Kiosk::Server::DeviceCodeGrant.start(client: client, store: store) }

    def poll(device_code = start[:device_code], key: agent_key, client_id: client.id)
      token_request({ 'grant_type' => grant, 'device_code' => device_code, **assertion_params(client_id, key: key) },
                    key: key)
    end

    def approve(role: 'owner')
      Kiosk::Server::DeviceVerification.approve(user_code: start[:user_code], user_id: holder, role: role, store: store)
    end

    it 'answers authorization_pending until the holder approves' do
      expect_oauth_error(poll, 'authorization_pending')
    end

    it "binds the client to the approving holder and answers a token with the holder's role as scope" do
      approve
      status, _headers, body = poll

      expect(status).to eq(200)
      expect(body).to include('token_type' => 'DPoP', 'scope' => 'owner')
      expect(claims_of(body['access_token'])).to include('sub' => holder, 'agent_id' => client.id, 'role' => 'owner')
      expect(Kiosk::Server::Client.find(client.id).user_id).to eq(holder)
    end

    it 'answers invalid_grant to another client, and leaves the code for its own client' do
      approve
      other = register_client(other_key)
      expect_oauth_error(poll(key: other_key, client_id: other.id), 'invalid_grant')
      Kiosk::Server::DeviceCodeGrant.reset_poll_registry!
      expect(poll.first).to eq(200)
    end

    it 'answers invalid_client before it reads the code' do
      expect_oauth_error(poll('unknown', key: other_key), 'invalid_client', status: 401)
    end

    it 'answers invalid_request without a device_code' do
      expect_oauth_error(token_request({ 'grant_type' => grant, **assertion_params(client.id) }), 'invalid_request')
    end

    it 'answers unsupported_grant_type where the origin serves no binding' do
      Kiosk.configure { |c| c.serve_account_binding = false }
      expect_oauth_error(poll('any'), 'unsupported_grant_type')
    end

    it 'asks the toll on the first poll, before the client authenticates' do
      device_code = start[:device_code]
      Kiosk::Reputation::Backends.register('equihash', Kiosk::Pow::Equihash)
      allow(Kiosk::Pow::Equihash).to receive(:params).and_return({ n: 8, k: 1 })
      Kiosk.configure do |c|
        c.registration_pow_count = 1
        c.pow_secret             = 'registration-pow-secret-at-least-32-bytes'
      end

      status, headers, body = poll(device_code, key: other_key)
      expect(status).to eq(402)
      expect(headers['Content-Type']).to include('application/problem+json')
      expect(body['code']).to eq('pow_required')
    ensure
      Kiosk::Reputation::Backends.reset!
    end
  end
end
