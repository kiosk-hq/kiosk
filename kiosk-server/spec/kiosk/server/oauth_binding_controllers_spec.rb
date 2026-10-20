# frozen_string_literal: true

# Controller shims of the claim ceremony's OAuth wire.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host. Requests are form-encoded, as on the real OAuth wire.

require 'rack/mock'
require 'json'
require 'openssl'

module OauthBindingControllersSpecHelpers
  def dispatch(controller, action, path, params)
    env = Rack::MockRequest.env_for(
      "https://provider.example#{path}",
      method: 'POST',
      params: params # form-encoded body
    )
    status, _headers, body = controller.action(action).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  def start!(params)
    dispatch(
      Kiosk::Server::OauthDeviceAuthorizationController, :create,
      '/kiosk/oauth/device_authorization', params
    )
  end

  def token!(params)
    dispatch(Kiosk::Server::OauthTokenController, :create, '/kiosk/oauth/token', params)
  end

  def signed_proof
    challenge = Kiosk::Server::AuthChallenge.issue(public_key_pem: pem.strip)
    JWT.encode(
      { aud: 'https://provider.example', nonce: challenge[:challenge], jti: SecureRandom.uuid },
      rsa, 'RS256'
    )
  end

  def stub_binding
    allow(Kiosk::Server::AccountBinding).to receive(:bind!).and_return(
      { agent_id: 'a-1', user_id: user_id, access_token: 'kiosk-pop-jwt', fresh: true }
    )
  end
end

RSpec.shared_context 'oauth binding controllers spec: provider origin' do
  include OauthBindingControllersSpecHelpers

  let(:store) { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:rsa)   { OpenSSL::PKey::RSA.generate(2048) }
  let(:pem)   { rsa.public_key.to_pem }
  let(:user_id) { '11111111-1111-1111-1111-111111111111' }

  before do
    Kiosk.configure do |c|
      c.issuer                     = 'https://provider.example'
      c.roles                      = %i[customer]
      c.device_authorization_store = store
    end
    Kiosk::Server::DeviceCodeGrant.reset_poll_registry!
  end

  let(:grant) { Kiosk::Server::DeviceCodeGrant::GRANT_TYPE }
end

RSpec.describe Kiosk::Server::OauthDeviceAuthorizationController do
  include_context 'oauth binding controllers spec: provider origin'

  describe 'POST /oauth/device_authorization' do
    it 'opens a claim ceremony for a well-formed key (form-encoded)' do
      status, body = start!('client_id' => 'assistant', 'public_key' => pem)

      expect(status).to eq(200)
      expect(body[:device_code]).to be_a(String)
      expect(body[:user_code]).to match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
      expect(body[:verification_uri]).to eq('https://provider.example/kiosk/oauth/device/verify')
      expect(body[:verification_uri_complete]).to include(body[:user_code])
      expect(body[:expires_in]).to be_positive
      expect(body[:interval]).to be_positive
    end

    it 'requires public_key — the ceremony is key-bound (invalid_request)' do
      status, body = start!('client_id' => 'assistant')
      expect(status).to eq(400)
      expect(body[:error]).to eq('invalid_request')
      expect(body[:error_description]).to include('public_key')
    end

    it 'rejects an undersized key with the registration floor (RSA-2048)' do
      small = OpenSSL::PKey::RSA.generate(1024).public_key.to_pem
      status, body = start!('client_id' => 'assistant', 'public_key' => small)
      expect(status).to eq(400)
      expect(body[:error]).to eq('invalid_request')
      expect(body[:error_description]).to include('too small')
    end

    it 'rejects a malformed key' do
      status, body = start!('client_id' => 'assistant', 'public_key' => 'not-a-pem')
      expect(status).to eq(400)
      expect(body[:error]).to eq('invalid_request')
    end

    it 'still requires client_id' do
      status, body = start!('public_key' => pem)
      expect(status).to eq(400)
      expect(body[:error_description]).to include('client_id')
    end

    it 'refuses a client-supplied role — even one this provider declares' do
      status, body = start!('client_id' => 'assistant', 'public_key' => pem, 'role' => 'customer')
      expect(status).to eq(400)
      expect(body[:error]).to eq('invalid_request')
      expect(body[:error_description]).to include('role is not accepted here')
      expect(body[:error_description]).to include('does not choose its own role')
    end

    it 'refuses an undeclared role the same way — the value is never consulted' do
      status, body = start!('client_id' => 'assistant', 'public_key' => pem, 'role' => 'root')
      expect(status).to eq(400)
      expect(body[:error_description]).to include('role is not accepted here')
    end

    it 'refuses the OAuth-standard `scope` spelling too' do
      status, body = start!('client_id' => 'assistant', 'public_key' => pem, 'scope' => 'owner')
      expect(status).to eq(400)
      expect(body[:error_description]).to include('scope is not accepted here')
    end

    it 'refuses an EMPTY role or scope — the parameter itself is not accepted' do
      %w[role scope].each do |name|
        status, body = start!('client_id' => 'assistant', 'public_key' => pem, name => '')
        expect(status).to eq(400)
        expect(body[:error]).to eq('invalid_request')
        expect(body[:error_description]).to match(/#{name} is not accepted here/)
      end
    end

    it 'opens the ceremony with a ROLE-LESS row — the role is stamped at approval' do
      status, body = start!('client_id' => 'assistant', 'public_key' => pem)
      expect(status).to eq(200)

      row = store.lookup_by_device_code_hash(
        Kiosk::Server::DeviceAuthorization.hash_device_code(body[:device_code])
      )
      expect(row.requested_role).to be_nil
    end
  end

  describe Kiosk::Server::OauthTokenController do
    describe 'POST /oauth/token' do
      it 'requires a grant_type' do
        status, body = token!({})
        expect(status).to eq(400)
        expect(body[:error]).to eq('invalid_request')
      end

      it 'rejects non-device grants — kiosk-pop login is the refresh path' do
        status, body = token!('grant_type' => 'refresh_token')
        expect(status).to eq(400)
        expect(body[:error]).to eq('unsupported_grant_type')
      end

      it 'returns 400 with the RFC 8628 code while approval is pending' do
        start = Kiosk::Server::DeviceCodeGrant.start(client_id: 'assistant', public_key_pem: pem)
        status, body = token!('grant_type' => grant, 'device_code' => start[:device_code])
        expect(status).to eq(400)
        expect(body[:error]).to eq('authorization_pending')
      end

      it 'returns 401 invalid_client when the possession proof is missing/failed (BIND-POP)' do
        start = Kiosk::Server::DeviceCodeGrant.start(client_id: 'assistant', public_key_pem: pem)
        store.update(start[:da].approve(user_id: user_id))
        Kiosk::Server::DeviceCodeGrant.reset_poll_registry!

        status, body = token!('grant_type' => grant, 'device_code' => start[:device_code])
        expect(status).to eq(401)
        expect(body[:error]).to eq('invalid_client')
      end

      it 'completes the ceremony with a valid proof: binds and returns the kiosk-pop token' do
        start = Kiosk::Server::DeviceCodeGrant.start(client_id: 'assistant', public_key_pem: pem)
        store.update(start[:da].approve(user_id: user_id))
        Kiosk::Server::DeviceCodeGrant.reset_poll_registry!

        signed = signed_proof
        stub_binding

        status, body = token!(
          'grant_type' => grant, 'device_code' => start[:device_code], 'signed' => signed
        )
        expect(status).to eq(200)
        expect(body[:access_token]).to eq('kiosk-pop-jwt')
        expect(body[:token_type]).to eq('Bearer')
        expect(Kiosk::Server::AccountBinding).to have_received(:bind!).with(
          public_key_pem: pem.strip, user_id: user_id, requested_role: nil
        )
      end

      # The role that reaches `bind!` is the one the APPROVER carried, although
      # the opening request said nothing. The `scope` echoed back is that same
      # granted role.
      it "forwards the APPROVING human's role to bind! and echoes it as the granted scope" do
        Kiosk.configure { |c| c.roles = %i[customer owner] }
        start = Kiosk::Server::DeviceCodeGrant.start(client_id: 'assistant', public_key_pem: pem)
        Kiosk::Server::DeviceVerification.approve(
          user_code: start[:user_code], user_id: user_id, role: 'owner', store: store
        )
        Kiosk::Server::DeviceCodeGrant.reset_poll_registry!

        signed = signed_proof
        stub_binding

        status, body = token!(
          'grant_type' => grant, 'device_code' => start[:device_code], 'signed' => signed
        )
        expect(status).to eq(200)
        expect(body[:scope]).to eq('owner')
        expect(Kiosk::Server::AccountBinding).to have_received(:bind!).with(
          public_key_pem: pem.strip, user_id: user_id, requested_role: 'owner'
        )
      end
    end
  end
end
