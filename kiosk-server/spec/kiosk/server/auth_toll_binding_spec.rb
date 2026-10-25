# frozen_string_literal: true

# The auth toll on the two binding redeems: the link-code claim and the
# device-code token poll. The toll is asked before the code is looked up, so
# the answer to a request with no proof never says whether the code exists. Driven
# with the kiosk-pow-equihash known-answer proof (n=8, k=1).

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

  def claim_proof(code, id:) = proof_for(verb: 'auth/claim', body: { code: code }, id: id)

  def poll_proof(device_code, id:) = proof_for(verb: 'oauth/token', body: { device_code: device_code }, id: id)
end

RSpec.shared_context 'with a tolled provider for binding' do
  include_context 'with registered clients'
  include AuthTollBindingSpec

  let(:store) { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:client) { register_client }

  before do
    # Registered before the toll is on: registration is tolled too.
    client
    Kiosk::Reputation::Backends.register('equihash', Kiosk::Pow::Equihash)
    allow(Kiosk::Pow::Equihash).to receive(:params).and_return(EquihashKat::PARAMS)
    Kiosk.configure do |c|
      c.device_authorization_store = store
      c.registration_pow_count     = 1
      c.pow_secret                 = AuthTollBindingSpec::SECRET
    end
    Kiosk::Server::DeviceCodeGrant.reset_poll_registry!
  end

  after { Kiosk::Reputation::Backends.reset! }
end

RSpec.describe Kiosk::Server::AuthToll do
  include_context 'with a tolled provider for binding'

  describe Kiosk::Server::LinkCode do
    let(:code) { described_class.mint(user_id: holder!, requested_role: 'customer', store: store)[:link_code] }

    def redeem(code, pow: nil)
      described_class.redeem(code: code, assertion_type: Kiosk::Server::ClientAssertion::TYPE,
                             assertion: client_assertion(client.id), pow: pow, store: store)
    end

    it 'asks an unknown link code for the toll, the same as a live one' do
      challenges = [SecureRandom.urlsafe_base64(32), code].map do |each_code|
        redeem(each_code)
      rescue Kiosk::Server::Errors::PowRequired => e
        e.challenges.size
      end
      expect(challenges).to eq([1, 1])
    end

    it 'answers a claim of an unknown link code with a valid proof not found' do
      unknown = SecureRandom.urlsafe_base64(32)
      expect { redeem(unknown, pow: claim_proof(unknown, id: 'unknown')) }.to raise_error(Kiosk::Server::Errors::NotFound)
    end

    it 'binds a claim of a live link code with a valid proof' do
      expect(redeem(code, pow: claim_proof(code, id: 'live')).id).to eq(client.id)
    end

    it 'refuses a proof solved for another link code' do
      expect { redeem(code, pow: claim_proof('another', id: 'other')) }.to raise_error(Kiosk::Server::Errors::PowRequired)
    end
  end

  describe Kiosk::Server::DeviceCodeGrant do
    let(:unknown) { SecureRandom.urlsafe_base64(32) }

    it 'asks the first poll of an unknown device code for the toll before it reads the store' do
      allow(store).to receive(:lookup_by_device_code_hash)
      expect { described_class.pay_toll!(unknown, nil) }.to raise_error(Kiosk::Server::Errors::PowRequired)
      expect(store).not_to have_received(:lookup_by_device_code_hash)
    end

    it 'charges each device code once: later polls of the same code are free' do
      described_class.pay_toll!(unknown, poll_proof(unknown, id: 'first'))
      expect { described_class.pay_toll!(unknown, nil) }.not_to raise_error
    end

    it 'asks the toll again for another device code' do
      described_class.pay_toll!(unknown, poll_proof(unknown, id: 'first'))
      expect { described_class.pay_toll!('another', nil) }.to raise_error(Kiosk::Server::Errors::PowRequired)
    end

    it 'asks nothing when the toll is off' do
      Kiosk.configuration.registration_pow_count = 0
      expect { described_class.pay_toll!(unknown, nil) }.not_to raise_error
    end
  end

  describe Kiosk::Server::OauthTokenController do
    let(:grant) { Kiosk::Server::DeviceCodeGrant::GRANT_TYPE }
    let(:live)  { Kiosk::Server::DeviceCodeGrant.start(client: client, store: store)[:device_code] }

    def poll(code, headers = {})
      token_request({ 'grant_type' => grant, 'device_code' => code, **assertion_params(client.id) }, headers: headers)
    end

    it 'answers a poll with no proof with the 402 problem document, the same for an unknown and a live code' do
      answers = [SecureRandom.urlsafe_base64(32), live].map do |code|
        status, headers, body = poll(code)
        [status, headers['WWW-Authenticate'], headers['Cache-Control'], body['code'], body['challenges'].size]
      end
      expect(answers.uniq).to eq([[402, %(Kiosk-PoW realm="#{OauthClients::ISSUER}"), 'no-store', 'pow_required', 1]])
    end

    it 'answers a malformed Kiosk-PoW header 400 bad_request as a problem document' do
      status, headers, body = poll(live, 'HTTP_KIOSK_POW' => '{not json')
      expect([status, body['code']]).to eq([400, 'bad_request'])
      expect(headers['Content-Type']).to include('application/problem+json')
    end

    it 'answers a poll with a valid proof on the OAuth endpoints' do
      status, _headers, body = poll(live, 'HTTP_KIOSK_POW' => JSON.generate(poll_proof(live, id: 'ctl-live')))
      expect([status, body['error']]).to eq([400, 'authorization_pending'])
    end
  end
end
