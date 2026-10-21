# frozen_string_literal: true

# RFC 7591 open registration against the shipped agents table: the metadata
# checks, the assistant account, the role and the one client per live key.
RSpec.describe Kiosk::Server::ClientRegistration do
  include_context 'with registered clients'

  let(:metadata) { { 'jwks' => jwks_of(agent_key) } }

  def register(body = metadata, **) = described_class.call(body, **)

  def expect_invalid(message, &)
    expect(&).to raise_error(Kiosk::Server::OauthError, message) { |e| expect(e.code).to eq('invalid_client_metadata') }
  end

  def agent_count = ActiveRecord::Base.connection.select_value(%(SELECT count(*) FROM "#{OauthClients::SCHEMA}".agents))

  it 'creates an assistant account and a client with the registration role' do
    client = register
    expect(client.role).to eq('customer')
    expect(client.thumbprint).to eq(agent_jkt)
    expect(OauthClients::User.exists?(client.user_id)).to be(true)
  end

  it 'answers the client information of RFC 7591 Section 3.2.1' do
    info = register.information
    expect(info).to include(token_endpoint_auth_method: 'private_key_jwt', dpop_bound_access_tokens: true,
                            grant_types: ['client_credentials', Kiosk::Server::Client::DEVICE_CODE])
    expect(info[:client_id_issued_at]).to be_within(5).of(Time.now.to_i)
    expect(info[:jwks]).to eq(keys: [Kiosk::Server::AssistantKey.to_jwk(agent_key.public_key)])
  end

  it 'answers the same client for a key that has a live client, and creates nothing' do
    first = register
    expect(register.id).to eq(first.id)
    expect(agent_count).to eq(1)
  end

  it 'gives an unlinked key a new client and a new account' do
    first = register
    ActiveRecord::Base.connection.exec_query(
      %(UPDATE "#{OauthClients::SCHEMA}".agents SET revoked_at = now() WHERE id = $1), 'spec', [first.id]
    )
    second = register
    expect(second.id).not_to eq(first.id)
    expect(second.user_id).not_to eq(first.user_id)
  end

  it 'lists only client_credentials where the origin serves no binding' do
    Kiosk.configure { |c| c.serve_account_binding = false }
    expect(register.information[:grant_types]).to eq(['client_credentials'])
  end

  it 'accepts the requested auth method and a subset of the served grant types' do
    expect { register(metadata.merge('token_endpoint_auth_method' => 'private_key_jwt', 'grant_types' => ['client_credentials'])) }
      .not_to raise_error
  end

  it 'ignores metadata members it does not know' do
    expect { register(metadata.merge('client_name' => 'x', 'redirect_uris' => ['https://x.example'])) }.not_to raise_error
  end

  it 'refuses a body with no usable key' do
    expect_invalid(/jwks: jwks must be a JWK Set/) { register({}) }
    expect_invalid(/private member/) { register({ 'jwks' => { 'keys' => [jwks_of(agent_key)['keys'].first.merge('d' => 'x')] } }) }
    expect_invalid(/JSON object/) { register([]) }
  end

  it 'refuses another auth method and a grant type the origin does not serve' do
    expect_invalid(/token_endpoint_auth_method/) { register(metadata.merge('token_endpoint_auth_method' => 'none')) }
    expect_invalid(/grant_types/) { register(metadata.merge('grant_types' => ['authorization_code'])) }
    Kiosk.configure { |c| c.serve_account_binding = false }
    expect_invalid(/grant_types/) { register(metadata.merge('grant_types' => [Kiosk::Server::Client::DEVICE_CODE])) }
  end

  it 'writes no row for a refused body' do
    expect_invalid(/token_endpoint_auth_method/) { register(metadata.merge('token_endpoint_auth_method' => 'none')) }
    expect(agent_count).to eq(0)
  end

  it 'writes an empty role list where the origin declares no roles' do
    Kiosk.configure do |c|
      c.roles = []
      c.registration_role = nil
    end
    expect(register.allowed_roles).to eq([]).or eq('{}')
  end

  it 'refuses a registration_role that is not among the configured roles' do
    Kiosk.configure { |c| c.registration_role = :admin }
    expect { register }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /registration_role/)
  end

  describe 'the assistant account factory (config.assistant_creation)' do
    it 'calls it with the stored PEM and uses its answer as the principal' do
      holder = holder!
      received = nil
      Kiosk.configure { |c| c.assistant_creation = ->(pem) { (received = pem) && holder } }
      expect(register.user_id).to eq(holder)
      expect(received).to eq(Kiosk::Server::AssistantKey.to_pem(agent_key.public_key))
    end

    it 'refuses a factory that answers nil' do
      Kiosk.configure { |c| c.assistant_creation = ->(_pem) {} }
      expect { register }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /assistant_creation returned nil/)
    end
  end

  it 'pays the toll before any lookup, on the key thumbprint' do
    allow(Kiosk::Server::AuthToll).to receive(:gate).and_raise(Kiosk::Server::Errors::Forbidden, 'toll')
    allow(Kiosk::Server::Client).to receive(:with_key)
    expect { register(metadata, pow: :proofs) }.to raise_error(Kiosk::Server::Errors::Forbidden)
    expect(Kiosk::Server::AuthToll).to have_received(:gate)
      .with(verb: 'oauth/register', body: { key: agent_jkt }, pow: :proofs, config: Kiosk.configuration)
    expect(Kiosk::Server::Client).not_to have_received(:with_key)
  end
end
