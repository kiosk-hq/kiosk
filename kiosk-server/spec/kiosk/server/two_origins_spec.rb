# frozen_string_literal: true

# ADR-0040: every origin a deployment serves is its own operator. Each reader of
# the issuer answers for the origin the request arrived on, so nothing made on
# one origin is accepted on another.

require "jwt"
require "rack/mock"
require "json"
require "stringio"
require "kiosk/pow/equihash"
require "kiosk/reputation"

RSpec.describe "two origins on one deployment" do
  let(:a) { "https://getgrocery.example" }
  let(:b) { "https://buymilk.example" }

  before do
    Kiosk.configure do |c|
      c.issuer             = a
      c.additional_origins = [b]
      c.signing_key        = Kiosk::Server::SigningKey.generate
      c.roles              = %i[customer]
    end
  end

  def through_middleware(app, url, **opts)
    status, headers, body = Kiosk::Server::IssuerMiddleware.new(app).call(Rack::MockRequest.env_for(url, **opts))
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw]
  end

  def discovery(action, origin, path)
    _, _, raw = through_middleware(Kiosk::Server::DiscoveryController.action(action), "#{origin}#{path}")
    JSON.parse(raw)
  end

  describe "discovery" do
    it "advertises each origin as its own issuer" do
      expect(discovery(:kiosk_json, a, "/.well-known/kiosk.json").dig("kiosk", "issuer")).to eq(a)
      expect(discovery(:kiosk_json, b, "/.well-known/kiosk.json").dig("kiosk", "issuer")).to eq(b)
      expect(discovery(:kiosk_json, b, "/.well-known/kiosk.json").dig("kiosk", "endpoint")).to eq("#{b}/kiosk")
      expect(discovery(:agent_configuration, b, "/.well-known/agent-configuration")["issuer"]).to eq(b)
    end

    it "names each origin by its own host when no owner is set" do
      expect(discovery(:agents_json, b, "/agents.json").dig("site", "name")).to eq("buymilk.example")
    end

    it "advertises the default issuer on a host the operator does not serve" do
      expect(discovery(:kiosk_json, "https://www.example.com", "/.well-known/kiosk.json").dig("kiosk", "issuer"))
        .to eq(a)
    end
  end

  describe "the possession proof" do
    let(:rsa) { OpenSSL::PKey::RSA.generate(2048) }

    def proof(aud) = JWT.encode({ aud: aud, nonce: "n", jti: "j" }, rsa, "RS256")

    it "accepts a proof for the origin being served" do
      payload = Kiosk.with_issuer(b) do
        Kiosk::Server::PopVerifier.verify!(public_key_pem: rsa.public_key.to_pem, signed: proof(b))
      end
      expect(payload[:aud]).to eq(b)
    end

    it "answers a host it does not serve as the default origin, and rejects a proof carrying that host" do
      unserved = "https://www.example.com"
      original = $stderr
      $stderr = StringIO.new
      Kiosk.with_issuer(Kiosk.configuration.issuer_for(unserved)) do
        payload = Kiosk::Server::PopVerifier.verify!(public_key_pem: rsa.public_key.to_pem, signed: proof(a))
        expect(payload[:aud]).to eq(a)
        expect { Kiosk::Server::PopVerifier.verify!(public_key_pem: rsa.public_key.to_pem, signed: proof(unserved)) }
          .to raise_error(Kiosk::Server::Errors::Unauthenticated, "proof audience mismatch")
      end
    ensure
      $stderr = original
    end

    it "rejects a proof for A presented on B" do
      original = $stderr
      $stderr = StringIO.new
      expect do
        Kiosk.with_issuer(b) do
          Kiosk::Server::PopVerifier.verify!(public_key_pem: rsa.public_key.to_pem, signed: proof(a))
        end
      end.to raise_error(Kiosk::Server::Errors::Unauthenticated, "proof audience mismatch")
    ensure
      $stderr = original
    end
  end

  describe "access tokens" do
    let(:idp) { Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new }

    def token_on(origin)
      Kiosk.with_issuer(origin) do
        Kiosk::Server::JwtIssuer.issue(claims: { sub: "u-1", agent_id: "a-1", actor: "agent" },
                                       audience: Kiosk.current_issuer)
      end
    end

    def verify_on(origin, token)
      Kiosk.with_issuer(origin) { idp.verify("HTTP_AUTHORIZATION" => "Bearer #{token}") }
    end

    it "mints a token whose iss and aud are the origin being served" do
      claims = JWT.decode(token_on(b), nil, false).first
      expect(claims.values_at("iss", "aud")).to eq([b, b])
    end

    it "accepts a token on the origin that minted it and refuses it on the other" do
      expect(verify_on(b, token_on(b))).to be_a(Kiosk::Identity)
      expect(verify_on(a, token_on(b))).to be_nil
    end
  end

  describe "mandates" do
    let(:agent_key) { OpenSSL::PKey::RSA.generate(2048) }

    before do
      allow_any_instance_of(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp)
        .to receive(:agent_payment_key).with("a-1").and_return(agent_key.public_key)
    end

    def intent(iss)
      JWT.encode({ iss: iss, agent_id: "a-1", user_id: "u-1", id: "intent-1", scope: "groceries",
                   cap_amount_cents: 500, currency: "eur", iat: Time.now.to_i, exp: Time.now.to_i + 600 },
                 agent_key, "RS256")
    end

    it "accepts a mandate issued for the origin being served and refuses one issued for the other" do
      identity = build_identity(agent_id: "a-1", user_id: "u-1")
      verified = Kiosk.with_issuer(b) do
        Kiosk::Server::MandateVerifier.verify_intent(raw_jws: intent(b), identity: identity)
      end
      expect(verified.issuer).to eq(b)
      expect do
        Kiosk.with_issuer(b) { Kiosk::Server::MandateVerifier.verify_intent(raw_jws: intent(a), identity: identity) }
      end.to raise_error(Kiosk::Server::Errors::Forbidden, /issuer mismatch/)
    end
  end

  describe "the WWW-Authenticate realm" do
    before do
      Kiosk::Reputation::Backends.register("equihash", Kiosk::Pow::Equihash)
      Kiosk.configure do |c|
        c.registration_pow_count  = 1
        c.registration_pow_params = { n: 8, k: 1 }
        c.pow_secret              = "registration-pow-secret-at-least-32-bytes"
      end
    end

    after { Kiosk::Reputation::Backends.reset! }

    it "names the origin the request arrived on" do
      _, headers, = through_middleware(
        Kiosk::Server::AuthController.action(:register), "#{b}/kiosk/auth/register",
        method: "POST", "CONTENT_TYPE" => "application/json",
        input: JSON.generate(public_key: "pem", signed: "not-reached")
      )
      expect(headers["WWW-Authenticate"]).to eq(%(Kiosk-PoW realm="#{b}"))
    end
  end

  it "defaults the KYC attestation audience to the origin being served" do
    expect(Kiosk.with_issuer(b) { Kiosk.configuration.kyc_audience }).to eq(b)
  end
end
