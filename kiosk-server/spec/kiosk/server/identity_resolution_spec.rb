# frozen_string_literal: true

require 'rack/mock'

module IdentityResolutionSpecHelpers
  def fixed_idp(identity) = Class.new { define_method(:verify) { |_r| identity } }.new
  def nil_idp             = Class.new { define_method(:verify) { |_r| nil } }.new
end

RSpec.describe Kiosk::Server::IdentityResolution do
  describe '.agent_idp' do
    include IdentityResolutionSpecHelpers

    it 'defaults to the bundled kiosk-pop DefaultAgentIdp' do
      expect(described_class.agent_idp)
        .to be_a(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
    end

    # T-104. The demos used to override this with a hand-copied composite whose
    # second arm parsed a self-asserted `agent:u-…:a-…:r-…` bearer into an
    # identity at ANY role, gated to `Rails.env.local?` (K-539). The override
    # and both arms are gone fleet-wide, which puts the default on the path of
    # every demo driver — so the default's refusal of that bearer is now the
    # live behaviour, not a fallback nobody exercised, and it is unconditional:
    # there is no environment in which the forgery resolves.
    it 'refuses a forged self-asserted agent bearer, in every environment' do
      Kiosk.configure do |c|
        c.agent_idp    = nil
        c.signing_key  = Kiosk::Server::SigningKey.generate
        c.issuer       = 'https://example.test'
      end
      forged = 'agent:u-11111111-1111-4111-8111-111111111111:a-forged:r-owner'

      %w[DPoP Bearer].each do |scheme|
        request = instance_double(ActionDispatch::Request, headers: { 'Authorization' => "#{scheme} #{forged}" })
        expect(described_class.agent_idp.verify(request)).to be_nil
      end
    end

    it 'honors a configured override' do
      custom = nil_idp
      Kiosk.configure { |c| c.agent_idp = custom }
      expect(described_class.agent_idp).to be(custom)
    end
  end

  describe '.resolve' do
    include IdentityResolutionSpecHelpers

    let(:url)            { 'https://demo.example/kiosk/catalog' }
    let(:agent_identity) { build_identity(actor: 'agent', claims: { cnf: cnf_for }) }
    let(:human_identity) { build_identity(actor: 'human', agent_id: nil) }

    before { Kiosk.configure { |c| c.issuer = 'https://demo.example' } }

    def request_with(env = {})
      ActionDispatch::Request.new(Rack::MockRequest.env_for(url, env))
    end

    def proven_request(key: agent_key, method: 'GET', at: url)
      request_with(dpop_env('tok', method: method, url: at, key: key))
    end

    it "returns the agent idp's identity once the DPoP proof shows the token's key" do
      Kiosk.configure do |c|
        c.agent_idp = fixed_idp(agent_identity)
        c.user_idp  = fixed_idp(human_identity)
      end
      expect(Kiosk.with_issuer('https://demo.example') { described_class.resolve(proven_request) }).to be(agent_identity)
    end

    it 'refuses a valid token with no DPoP proof, naming the DPoP scheme' do
      Kiosk.configure { |c| c.agent_idp = fixed_idp(agent_identity) }
      expect { Kiosk.with_issuer('https://demo.example') { described_class.resolve(request_with('HTTP_AUTHORIZATION' => 'DPoP tok')) } }
        .to raise_error(Kiosk::Server::Errors::AccessTokenRefused) { expect(it.response_headers).to eq('WWW-Authenticate' => 'DPoP algs="RS256"') }
    end

    it 'refuses a proof that another key signed' do
      Kiosk.configure { |c| c.agent_idp = fixed_idp(agent_identity) }
      other = OpenSSL::PKey::RSA.generate(2048)
      expect { Kiosk.with_issuer('https://demo.example') { described_class.resolve(proven_request(key: other)) } }
        .to raise_error(Kiosk::Server::Errors::AccessTokenRefused, /not the key the token is bound to/)
    end

    it 'refuses an identity whose token is bound to no key' do
      Kiosk.configure { |c| c.agent_idp = fixed_idp(build_identity(actor: 'agent')) }
      expect { Kiosk.with_issuer('https://demo.example') { described_class.resolve(proven_request) } }
        .to raise_error(Kiosk::Server::Errors::AccessTokenRefused, /bound to no key/)
    end

    it 'ignores a signed-in session: the operator user_idp never resolves a wire caller' do
      Kiosk.configure do |c|
        c.agent_idp = nil_idp
        c.user_idp  = fixed_idp(human_identity)
      end
      expect(described_class.resolve(request_with)).to be_nil
    end

    it 'returns nil when nothing resolves (caller raises 401 — fail closed)' do
      Kiosk.configure { |c| c.agent_idp = nil_idp }
      expect(described_class.resolve(request_with)).to be_nil
    end
  end
end
