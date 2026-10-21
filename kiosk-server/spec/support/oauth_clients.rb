# frozen_string_literal: true

require 'active_record'
require 'json'
require 'jwt'
require 'rack/mock'
require 'securerandom'

# Registered clients in a real Postgres, made with the shipped DDL, and the
# client side of the OAuth wire: registration bodies, client assertions
# (RFC 7523) and token-request DPoP proofs (RFC 9449).
module OauthClients
  SCHEMA = 'kiosk_oauth_spec'
  # `identity_tables_sql` references the principals table unqualified, so it lives in `public`.
  USERS  = 'kiosk_oauth_spec_users'
  ISSUER = 'https://provider.example'
  SIGNING_KEY = Kiosk::Server::SigningKey.generate
  # A second assistant key.
  OTHER_KEY = OpenSSL::PKey.generate_key('ED25519')

  # The `user_model` of the spec origin.
  class User < ApplicationRecord
    self.table_name = USERS
  end

  def self.create_tables
    return if @created

    conn = ActiveRecord::Base.connection
    SpecPostgres.recreate_schema(SCHEMA)
    conn.execute(%(DROP TABLE IF EXISTS "#{USERS}" CASCADE))
    conn.execute(%(CREATE TABLE "#{USERS}" (id uuid PRIMARY KEY DEFAULT gen_random_uuid())))
    conn.execute(Kiosk::Server::SchemaDefinitions.identity_tables_sql(schema: SCHEMA, user_id_type: :uuid, user_table: USERS))
    @created = true
  end

  def self.drop_tables
    return unless @created

    SpecPostgres.drop_schema(SCHEMA)
    ActiveRecord::Base.connection.execute(%(DROP TABLE IF EXISTS "#{USERS}" CASCADE))
    @created = false
  end

  def other_key = OTHER_KEY

  # A principal row; its id.
  def holder! = User.create!.id

  def jwks_of(key) = { 'keys' => [Kiosk::Server::AssistantKey.to_jwk(key).transform_keys(&:to_s)] }

  def register_client(key = agent_key) = Kiosk::Server::ClientRegistration.call({ 'jwks' => jwks_of(key) })

  # A client assertion by `key`; a claim given as nil is left out.
  def client_assertion(client_id, key: agent_key, **claims)
    payload = { iss: client_id, sub: client_id, aud: Kiosk.current_issuer, exp: Time.now.to_i + 60,
                jti: SecureRandom.uuid }.merge(claims).compact
    JWT.encode(payload, key, Kiosk::TestHelpers::Dpop.algorithm(key))
  end

  def assertion_params(client_id, key: agent_key, **claims)
    { 'client_assertion_type' => Kiosk::Server::ClientAssertion::TYPE,
      'client_assertion' => client_assertion(client_id, key: key, **claims) }
  end

  # The DPoP proof of a token request: no `ath`, because there is no token yet.
  def token_request_proof(url, key: agent_key, **claims)
    jwk = Kiosk::Server::AssistantKey.to_jwk(key)
    payload = { jti: SecureRandom.uuid, htm: 'POST', htu: url, iat: Time.now.to_i }.merge(claims).compact
    JWT.encode(payload, key, Kiosk::TestHelpers::Dpop.algorithm(key), { typ: 'dpop+jwt', jwk: jwk })
  end

  def token_url = "#{ISSUER}/kiosk/oauth/token"

  # [status, headers, parsed body] of a controller action, called as a Rack app.
  def call_action(controller, action, env)
    status, headers, body = controller.action(action).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? nil : JSON.parse(raw)]
  end

  # POST <endpoint>/oauth/token, form-encoded, with a DPoP proof of `key` unless `dpop` is given.
  def token_request(params, key: agent_key, dpop: token_request_proof(token_url, key: key), headers: {})
    env = Rack::MockRequest.env_for(token_url, method: 'POST', params: params)
    env['HTTP_DPOP'] = dpop if dpop
    call_action(Kiosk::Server::OauthTokenController, :create, env.merge(headers))
  end

  def client_credentials(client_id, key: agent_key, **)
    token_request({ 'grant_type' => 'client_credentials', **assertion_params(client_id, key: key) }, key: key, **)
  end
end

RSpec.shared_context 'with registered clients' do
  include OauthClients

  before do
    skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error

    OauthClients.create_tables
    ActiveRecord::Base.connection.execute(%(TRUNCATE "#{OauthClients::SCHEMA}".agents, "#{OauthClients::USERS}" CASCADE))
    Kiosk.configure do |c|
      c.schema            = OauthClients::SCHEMA
      c.issuer            = OauthClients::ISSUER
      c.signing_key       = OauthClients::SIGNING_KEY
      c.user_model        = 'OauthClients::User'
      c.roles             = %i[customer owner]
      c.registration_role = :customer
    end
  end
end

RSpec.configure do |config|
  config.after(:suite) { OauthClients.drop_tables unless SpecPostgres.error }
end
