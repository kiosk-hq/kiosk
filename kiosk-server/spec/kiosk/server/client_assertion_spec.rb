# frozen_string_literal: true

# Client authentication by `private_key_jwt` (RFC 7523): every check of the
# assertion, and its single use.
RSpec.describe Kiosk::Server::ClientAssertion do
  include_context 'with registered clients'

  let(:client) { register_client }
  let(:type)   { described_class::TYPE }

  # The operator log line of an audience mismatch.
  before { allow(described_class).to receive(:warn) }

  def authenticate(assertion = client_assertion(client.id), type: self.type, **)
    described_class.authenticate!(type, assertion, **)
  end

  def expect_refused(message, &)
    expect(&).to raise_error(described_class::Refused, message)
  end

  it 'answers the client of a correct assertion' do
    expect(authenticate.id).to eq(client.id)
  end

  it 'accepts `aud` as a one-element array' do
    expect(authenticate(client_assertion(client.id, aud: [OauthClients::ISSUER])).id).to eq(client.id)
  end

  it 'refuses an absent assertion and a wrong assertion type' do
    expect_refused(/client authentication required/) { authenticate('') }
    expect_refused(/unsupported client_assertion_type/) { authenticate(type: 'urn:other') }
  end

  it 'refuses an unknown client, also a sub that is not a UUID' do
    expect_refused(/unknown client/) { authenticate(client_assertion(SecureRandom.uuid)) }
    expect_refused(/unknown client/) { authenticate(client_assertion('agent-1')) }
  end

  it 'refuses an unlinked client' do
    ActiveRecord::Base.connection.exec_query(
      %(UPDATE "#{OauthClients::SCHEMA}".kiosk_agents SET revoked_at = now() WHERE id = $1), 'spec', [client.id]
    )
    expect_refused(/unknown client/) { authenticate }
  end

  it 'refuses an assertion that another key signed' do
    expect_refused(/signature invalid/) { authenticate(client_assertion(client.id, key: other_key)) }
  end

  it 'refuses an algorithm other than the one of the registered key: RS256, ES256, an HMAC keyed with the public key' do
    payload = { iss: client.id, sub: client.id, aud: OauthClients::ISSUER, exp: Time.now.to_i + 60, jti: 'j' }
    expect_refused(/alg is not EdDSA/) { authenticate(JWT.encode(payload, client.public_key_pem, 'HS256')) }
    expect_refused(/alg is not EdDSA/) { authenticate(JWT.encode(payload, OpenSSL::PKey::RSA.generate(2048), 'RS256')) }
    expect_refused(/alg is not EdDSA/) { authenticate(JWT.encode(payload, Kiosk::TestHelpers::Dpop.generate_key('ES256'), 'ES256')) }
  end

  it 'refuses an assertion that the registered key signed under the alg of another key type' do
    payload = { iss: client.id, sub: client.id, aud: OauthClients::ISSUER, exp: Time.now.to_i + 60, jti: 'j' }
    %w[RS256 ES256].each do |alg|
      expect_refused(/alg is not EdDSA, the algorithm of your registered key/) { authenticate(mislabelled_jws(payload, agent_key, alg)) }
    end
    Kiosk.configure { |c| c.assistant_algorithms = %w[EdDSA ES256] }
    p256 = Kiosk::TestHelpers::Dpop.generate_key('ES256')
    ec_client = register_client(p256)
    ec_payload = payload.merge(iss: ec_client.id, sub: ec_client.id)
    expect_refused(/alg is not ES256, the algorithm of your registered key/) { authenticate(mislabelled_jws(ec_payload, p256, 'EdDSA')) }
  end

  it 'refuses a client whose registered key this operator no longer accepts, and says to register a new key' do
    Kiosk.configure { |c| c.assistant_algorithms = %w[EdDSA ES256] }
    p256 = Kiosk::TestHelpers::Dpop.generate_key('ES256')
    ec_client = register_client(p256)
    Kiosk.configure { |c| c.assistant_algorithms = %w[EdDSA] }
    expect_refused(/registered key is not accepted here/) { authenticate(client_assertion(ec_client.id, key: p256)) }
  end

  it 'refuses an assertion that is not a JWT' do
    expect_refused(/not a JWT/) { authenticate('not-a-jwt') }
  end

  it 'refuses an assertion with no jti, or with iss other than sub' do
    expect_refused(/missing a required claim/) { authenticate(client_assertion(client.id, jti: nil)) }
    expect_refused(/iss is not its sub/) { authenticate(client_assertion(client.id, iss: 'someone')) }
  end

  it 'refuses an `aud` that is another origin, or that names a second audience' do
    expect_refused(/audience mismatch/) { authenticate(client_assertion(client.id, aud: 'https://relay.example')) }
    expect_refused(/audience mismatch/) do
      authenticate(client_assertion(client.id, aud: [OauthClients::ISSUER, 'https://relay.example']))
    end
  end

  it "logs the signed `aud` and this request's issuer for the operator, and names no origin to the caller" do
    expect_refused(/audience mismatch/) { authenticate(client_assertion(client.id, aud: 'https://relay.example')) }
    expect(described_class).to have_received(:warn)
      .with(%r{signed aud="https://relay.example", the issuer for this request is "https://provider.example"})
  end

  it 'refuses an expired assertion and one that lives more than 300 seconds' do
    expect_refused(/expired/) { authenticate(client_assertion(client.id, exp: Time.now.to_i - 120)) }
    expect_refused(/lives too long/) { authenticate(client_assertion(client.id, exp: Time.now.to_i + 600)) }
  end

  it 'refuses a client_id that is not the sub' do
    expect_refused(/client_id is not the client assertion sub/) { authenticate(client_id: SecureRandom.uuid) }
  end

  it 'accepts each jti one time' do
    assertion = client_assertion(client.id)
    authenticate(assertion)
    expect_refused(/already used/) { authenticate(assertion) }
  end

  it 'spends no jti on a expect_refused assertion' do
    assertion = client_assertion(client.id, aud: 'https://relay.example')
    expect_refused(/audience mismatch/) { authenticate(assertion) }
    expect(Kiosk.configuration.pow_spent_store.spent?("client_assertion:#{client.id}:#{JWT.decode(assertion, nil, false).first['jti']}"))
      .to be(false)
  end

  it 'gives a hint that says what to fix' do
    expect { authenticate(client_assertion(client.id, aud: 'https://relay.example')) }
      .to raise_error(described_class::Refused) { |e|
        expect(e.hint).to include('the origin you connected to')
        expect(e.to_oauth.code).to eq('invalid_client')
        expect(e.to_problem.http_status).to eq(401)
      }
  end
end
