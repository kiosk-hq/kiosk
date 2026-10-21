# frozen_string_literal: true

# ADR-0040: every origin a deployment serves is its own operator. Each reader of
# the issuer answers for the origin the request arrived on, so nothing made on
# one origin is accepted on another.

require 'jwt'
require 'rack/mock'
require 'json'
require 'stringio'
require 'kiosk/pow/equihash'
require 'kiosk/reputation'

module TwoOriginsSpec
  def through_middleware(app, url, **)
    status, headers, body = Kiosk::Server::IssuerMiddleware.new(app).call(Rack::MockRequest.env_for(url, **))
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, headers, raw]
  end

  def discovery(action, origin, path)
    _, _, raw = through_middleware(Kiosk::Server::DiscoveryController.action(action), "#{origin}#{path}")
    JSON.parse(raw)
  end

  CLIENT_ID = '0f1e2d3c-4b5a-4968-8778-695a4b3c2d1e'

  def assertion(aud)
    JWT.encode({ iss: CLIENT_ID, sub: CLIENT_ID, aud: aud, exp: Time.now.to_i + 60, jti: SecureRandom.uuid },
               agent_key, 'EdDSA')
  end

  # The claims of a verified client assertion. The client is the suite key's,
  # on whichever origin the request is answered as.
  def verify_assertion(aud)
    client = Kiosk::Server::Client.new(id: CLIENT_ID, user_id: 'u-1', public_key_pem: agent_pem, allowed_roles: [],
                                       issued_at: 0)
    allow(Kiosk::Server::Client).to receive(:find).with(CLIENT_ID).and_return(client)
    Kiosk::Server::ClientAssertion.verify(Kiosk::Server::ClientAssertion::TYPE, assertion(aud)).claims
  end

  # Run the block with $stderr captured, so the refusal log stays out of the output.
  def quietly
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end
end

RSpec.shared_context 'with a two-origin deployment' do
  include TwoOriginsSpec

  let(:a) { 'https://getgrocery.example' }
  let(:b) { 'https://buymilk.example' }

  before do
    Kiosk.configure do |c|
      c.issuer             = a
      c.additional_origins = [b]
      c.signing_key        = Kiosk::Server::SigningKey.generate
      c.roles              = %i[customer]
    end
  end
end

RSpec.describe Kiosk::Server::IssuerMiddleware do
  describe 'two origins on one deployment' do
    include_context 'with a two-origin deployment'

    describe 'discovery' do
      it 'advertises each origin as its own issuer' do
        expect(discovery(:kiosk_json, a, '/.well-known/kiosk.json').dig('kiosk', 'issuer')).to eq(a)
        expect(discovery(:kiosk_json, b, '/.well-known/kiosk.json').dig('kiosk', 'issuer')).to eq(b)
        expect(discovery(:kiosk_json, b, '/.well-known/kiosk.json').dig('kiosk', 'endpoint')).to eq("#{b}/kiosk")
        expect(discovery(:oauth_authorization_server, b, '/.well-known/oauth-authorization-server')['issuer']).to eq(b)
      end

      it 'names each origin by its own host when no owner is set' do
        expect(discovery(:agents_json, b, '/agents.json').dig('site', 'name')).to eq('buymilk.example')
      end

      it 'advertises the default issuer on a host the operator does not serve' do
        expect(discovery(:kiosk_json, 'https://www.example.com', '/.well-known/kiosk.json').dig('kiosk', 'issuer'))
          .to eq(a)
      end
    end

    describe 'the client assertion' do
      it 'accepts an assertion for the origin being served' do
        expect(Kiosk.with_issuer(b) { verify_assertion(b) }['aud']).to eq(b)
      end

      it 'answers a host it does not serve as the default origin, and rejects an assertion carrying that host' do
        unserved = 'https://www.example.com'
        quietly do
          Kiosk.with_issuer(Kiosk.configuration.issuer_for(unserved)) do
            expect(verify_assertion(a)['aud']).to eq(a)
            expect { verify_assertion(unserved) }
              .to raise_error(Kiosk::Server::ClientAssertion::Refused, 'client assertion audience mismatch')
          end
        end
      end

      it 'rejects an assertion for A presented on B' do
        quietly do
          expect { Kiosk.with_issuer(b) { verify_assertion(a) } }
            .to raise_error(Kiosk::Server::ClientAssertion::Refused, 'client assertion audience mismatch')
        end
      end
    end

    describe 'access tokens' do
      let(:idp) { Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new }

      def token_on(origin)
        Kiosk.with_issuer(origin) do
          Kiosk::Server::JwtIssuer.issue(claims: { sub: 'u-1', agent_id: 'a-1', actor: 'agent', cnf: cnf_for },
                                         audience: Kiosk.current_issuer)
        end
      end

      def verify_on(origin, token)
        Kiosk.with_issuer(origin) { idp.verify('HTTP_AUTHORIZATION' => "DPoP #{token}") }
      end

      it 'mints a token whose iss and aud are the origin being served' do
        claims = JWT.decode(token_on(b), nil, false).first
        expect(claims.values_at('iss', 'aud')).to eq([b, b])
      end

      it 'accepts a token on the origin that minted it and refuses it on the other' do
        expect(verify_on(b, token_on(b))).to be_a(Kiosk::Identity)
        expect(verify_on(a, token_on(b))).to be_nil
      end
    end

    describe 'checkouts' do
      include_context 'with a checkout to pay'

      let(:identity) { build_identity(agent_id: 'agent-1', user_id: 'u-1') }

      def mandate_for(origin)
        Kiosk::TestHelpers::Mandate.pay(agent_key, Kiosk.with_issuer(origin) { checkout })[:checkout]
      end

      it 'accepts a checkout signed for the origin being served and refuses one signed for the other' do
        verified = Kiosk.with_issuer(b) do
          Kiosk::Server::MandateVerifier.verify_checkout(sd_jwt: mandate_for(b), identity: identity)
        end
        expect(verified.issuer).to eq(b)
        expect do
          Kiosk.with_issuer(b) { Kiosk::Server::MandateVerifier.verify_checkout(sd_jwt: mandate_for(a), identity: identity) }
        end.to raise_error(Kiosk::Server::Errors::Forbidden, /not from this origin/)
      end
    end

    describe 'the WWW-Authenticate realm' do
      before do
        Kiosk::Reputation::Backends.register('equihash', Kiosk::Pow::Equihash)
        allow(Kiosk::Pow::Equihash).to receive(:params).and_return({ n: 8, k: 1 })
        Kiosk.configure do |c|
          c.registration_pow_count = 1
          c.pow_secret             = 'registration-pow-secret-at-least-32-bytes'
        end
      end

      after { Kiosk::Reputation::Backends.reset! }

      it 'names the origin the request arrived on' do
        _, headers, = through_middleware(
          Kiosk::Server::OauthRegistrationController.action(:create), "#{b}/kiosk/oauth/register",
          method: 'POST', 'CONTENT_TYPE' => 'application/json',
          input: JSON.generate(jwks: { keys: [Kiosk::Server::AssistantKey.to_jwk(agent_key)] })
        )
        expect(headers['WWW-Authenticate']).to eq(%(Kiosk-PoW realm="#{b}"))
      end
    end

    it 'defaults the KYC attestation audience to the origin being served' do
      expect(Kiosk.with_issuer(b) { Kiosk.configuration.kyc_audience }).to eq(b)
    end
  end
end
