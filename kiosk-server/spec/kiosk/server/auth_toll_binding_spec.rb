# frozen_string_literal: true

# The auth toll on the two binding redeems: the link-code claim and the
# device-code token poll. The toll is asked before the code is looked up, so
# the answer to an unpaid request never says whether the code exists. Driven
# with the kiosk-pow-equihash known-answer proof (n=8, k=1).

require 'rack/mock'
require 'json'
require 'openssl'
require 'jwt'
require 'kiosk/reputation'
require 'kiosk/pow/equihash'
require_relative '../../support/equihash_kat'

module AuthTollBindingSpec
  SECRET = 'auth-toll-binding-secret-at-least-32-bytes'

  def proof_for(verb:, body:, id:)
    fp = Kiosk::Server::PowGate.request_fingerprint(method: 'POST', verb: verb, body: body)
    challenge = Kiosk::Reputation::Challenge.issue(
      alg: 'equihash', params: EquihashKat::PARAMS, request_fingerprint: fp,
      secret: SECRET, ttl: 300, salt: EquihashKat::SALT.b, id: id
    )
    [{ challenge: challenge, nonce: EquihashKat::NONCE }]
  end

  def claim_proof(code, id:) = proof_for(verb: 'auth/claim', body: { code: code, public_key: pem.strip }, id: id)

  def poll_proof(device_code, id:) = proof_for(verb: 'oauth/token', body: { device_code: device_code }, id: id)

  def possession
    challenge = Kiosk::Server::AuthChallenge.issue(public_key_pem: pem.strip)
    JWT.encode({ aud: 'https://provider.example', nonce: challenge[:challenge], jti: SecureRandom.uuid }, rsa, 'RS256')
  end

  def poll(device_code, pow: nil, now: Time.current)
    Kiosk::Server::DeviceCodeGrant.exchange(device_code: device_code, signed: possession, pow: pow, now: now)
  end

  def token!(params, headers = {})
    env = Rack::MockRequest.env_for('https://provider.example/kiosk/oauth/token',
                                    { method: 'POST', params: params }.merge(headers))
    status, response_headers, body = Kiosk::Server::OauthTokenController.action(:create).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, response_headers, JSON.parse(raw, symbolize_names: true)]
  end
end

RSpec.shared_context 'with a tolled provider for binding' do
  include AuthTollBindingSpec

  let(:store)   { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:rsa)     { OpenSSL::PKey::RSA.generate(2048) }
  let(:pem)     { rsa.public_key.to_pem }
  let(:user_id) { '11111111-1111-1111-1111-111111111111' }

  before do
    Kiosk::Reputation::Backends.register('equihash', Kiosk::Pow::Equihash)
    allow(Kiosk::Pow::Equihash).to receive(:params).and_return(EquihashKat::PARAMS)
    Kiosk.configure do |c|
      c.issuer                     = 'https://provider.example'
      c.roles                      = %i[customer]
      c.device_authorization_store = store
      c.registration_pow_count     = 1
      c.pow_secret                 = AuthTollBindingSpec::SECRET
    end
    Kiosk::Server::DeviceCodeGrant.reset_poll_registry!
    allow(Kiosk::Server::AccountBinding).to receive(:bind!)
      .and_return({ agent_id: 'a-1', user_id: user_id, access_token: 'kiosk-pop-jwt', fresh: true })
  end

  after do
    Kiosk::Reputation::Backends.reset!
    Kiosk.reset!
  end
end

RSpec.describe Kiosk::Server::AuthToll do
  include_context 'with a tolled provider for binding'

  describe Kiosk::Server::LinkCode do
    let(:live) { described_class.mint(user_id: user_id, store: store)[:link_code] }
    let(:unknown) { SecureRandom.urlsafe_base64(32) }

    def redeem(code, pow: nil)
      described_class.redeem(code: code, public_key_pem: pem, signed: possession, pow: pow, store: store)
    end

    it 'asks an unknown link code for the toll, the same as a live one' do
      asked = [unknown, live].map do |code|
        redeem(code)
      rescue Kiosk::Server::Errors::PowRequired => e
        e.challenges.map { it.slice(:alg, :params) }
      end
      expect(asked.uniq).to eq([[{ alg: 'equihash', params: EquihashKat::PARAMS }]])
    end

    it 'answers a paid claim of an unknown link code not found' do
      expect { redeem(unknown, pow: claim_proof(unknown, id: 'c-unknown')) }
        .to raise_error(Kiosk::Server::Errors::NotFound, /unknown link code/)
    end

    it 'binds a paid claim of a live link code' do
      expect(redeem(live, pow: claim_proof(live, id: 'c-live'))).to include(access_token: 'kiosk-pop-jwt')
    end

    it 'refuses a proof paid for another link code' do
      expect { redeem(live, pow: claim_proof(unknown, id: 'c-other')) }
        .to raise_error(Kiosk::Server::Errors::PowRequired)
    end
  end

  describe Kiosk::Server::DeviceCodeGrant do
    let(:live) { described_class.start(client_id: 'assistant', public_key_pem: pem, store: store)[:device_code] }
    let(:unknown) { SecureRandom.urlsafe_base64(32) }

    it 'asks the first poll of an unknown device code for the toll before it reads the store' do
      allow(store).to receive(:lookup_by_device_code_hash).and_call_original
      expect { poll(unknown) }.to raise_error(Kiosk::Server::Errors::PowRequired)
      expect(store).not_to have_received(:lookup_by_device_code_hash)
    end

    it 'answers a paid poll of an unknown device code invalid_grant' do
      expect(poll(unknown, pow: poll_proof(unknown, id: 'p-unknown'))).to include(error: 'invalid_grant')
    end

    it 'charges each device code once: later polls of the same code are free' do
      now = Time.current
      expect(poll(live, pow: poll_proof(live, id: 'p-live'), now: now)).to include(error: 'authorization_pending')
      expect(poll(live, now: now + 1)).to include(error: 'slow_down')
      expect(poll(live, now: now + 10)).to include(error: 'authorization_pending')
    end

    it 'asks the toll again for another device code' do
      poll(live, pow: poll_proof(live, id: 'p-first'))
      expect { poll(unknown) }.to raise_error(Kiosk::Server::Errors::PowRequired)
    end

    it 'asks nothing when the toll is off' do
      Kiosk.configuration.registration_pow_count = 0
      expect(poll(unknown)).to include(error: 'invalid_grant')
    end
  end

  describe Kiosk::Server::OauthTokenController do
    let(:grant) { Kiosk::Server::DeviceCodeGrant::GRANT_TYPE }
    let(:live) { Kiosk::Server::DeviceCodeGrant.start(client_id: 'assistant', public_key_pem: pem, store: store)[:device_code] }

    it 'answers an unpaid poll with the 402 problem document, the same for an unknown and a live code' do
      answers = [SecureRandom.urlsafe_base64(32), live].map do |code|
        status, headers, body = token!('grant_type' => grant, 'device_code' => code)
        [status, headers['WWW-Authenticate'], headers['Cache-Control'], body[:code], body[:challenges].size]
      end
      expect(answers.uniq).to eq([[402, 'Kiosk-PoW realm="https://provider.example"', 'no-store', 'pow_required', 1]])
    end

    it 'answers a malformed Kiosk-PoW header 400 bad_request as a problem document' do
      status, headers, body = token!({ 'grant_type' => grant, 'device_code' => live }, 'HTTP_KIOSK_POW' => '{not json')
      expect([status, body[:code]]).to eq([400, 'bad_request'])
      expect(headers['Content-Type']).to include('application/problem+json')
    end

    it 'answers a paid poll on the OAuth wire' do
      proof = JSON.generate(poll_proof(live, id: 'ctl-live'))
      status, _headers, body = token!({ 'grant_type' => grant, 'device_code' => live, 'signed' => possession },
                                      'HTTP_KIOSK_POW' => proof)
      expect([status, body[:error]]).to eq([400, 'authorization_pending'])
    end
  end
end
