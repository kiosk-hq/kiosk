# frozen_string_literal: true

require "spec_helper"
require "digest"
require "openssl"
require "jwt"

RSpec.describe Kiosk::Redteam::Client do
  let(:base_url) { "http://kiosk.example.com" }
  let(:client)   { described_class.new(base_url:) }

  # Shared stub response bodies
  let(:register_body) do
    JSON.generate("agent_id" => "agent-123", "user_id" => "user-456", "access_token" => "tok-abc")
  end

  # ── register_raw ────────────────────────────────────────────────────────

  describe "#register_raw" do
    it "returns a Response" do
      stub_request(:post, "#{base_url}/kiosk/agents/register")
        .to_return(status: 201, body: register_body, headers: { "Content-Type" => "application/json" })

      result = client.register_raw(name: "test-agent")
      expect(result).to be_a(Kiosk::Redteam::Response)
      expect(result.status).to eq(201)
    end

    context "when pow: :skip" do
      it "posts without a pow field" do
        req_stub = stub_request(:post, "#{base_url}/kiosk/agents/register")
          .to_return(status: 422, body: JSON.generate("error" => { "code" => "pow_required" }),
                     headers: { "Content-Type" => "application/json" })

        client.register_raw(name: "no-pow", pow_difficulty: 20, pow: :skip)

        expect(req_stub).to have_been_requested.once
        # Verify the request body did NOT contain a pow field
        expect(
          WebMock::RequestRegistry.instance.requested_signatures.hash.keys.any? do |sig|
            body = JSON.parse(sig.body) rescue {}
            body.key?("pow")
          end
        ).to be(false)
      end
    end

    context "when pow is a verbatim String" do
      it "sends that exact string as the pow field" do
        captured_body = nil
        stub_request(:post, "#{base_url}/kiosk/agents/register")
          .with { |req| captured_body = JSON.parse(req.body); true }
          .to_return(status: 422, body: JSON.generate("error" => { "code" => "bad_request" }),
                     headers: { "Content-Type" => "application/json" })

        client.register_raw(name: "bad-pow-agent", pow_difficulty: 20, pow: "definitely_wrong_proof")

        expect(captured_body["pow"]).to eq("definitely_wrong_proof")
      end
    end
  end

  # ── register! ───────────────────────────────────────────────────────────

  describe "#register!" do
    context "with pow_difficulty: 0 (no PoW required)" do
      it "posts without a pow field and returns a Principal" do
        captured_body = nil
        stub_request(:post, "#{base_url}/kiosk/agents/register")
          .with { |req| captured_body = JSON.parse(req.body); true }
          .to_return(status: 201, body: register_body, headers: { "Content-Type" => "application/json" })

        principal = client.register!(name: "fooagent")

        expect(principal).to be_a(Kiosk::Redteam::Principal)
        expect(principal.agent_id).to eq("agent-123")
        expect(principal.user_id).to eq("user-456")
        expect(principal.token).to eq("tok-abc")
        expect(principal.rsa_key).to be_a(OpenSSL::PKey::RSA)
        # No pow field when difficulty is 0
        expect(captured_body).not_to have_key("pow")
      end
    end

    context "with pow_difficulty: 1 (minimal difficulty, fast in specs)" do
      it "posts a pow field whose SHA256 hash satisfies the difficulty" do
        captured_body = nil
        stub_request(:post, "#{base_url}/kiosk/agents/register")
          .with { |req| captured_body = JSON.parse(req.body); true }
          .to_return(status: 201, body: register_body, headers: { "Content-Type" => "application/json" })

        client.register!(name: "pow-agent", pow_difficulty: 1, pow: :solve)

        expect(captured_body).to have_key("pow")
        pem = captured_body.fetch("public_key")
        pow = captured_body.fetch("pow")

        # Verify the solved PoW actually satisfies difficulty=1
        digest = Digest::SHA256.digest("#{pem}.#{pow}")
        leading_zeros = count_leading_zero_bits(digest)
        expect(leading_zeros).to be >= 1
      end
    end

    context "with pow: :skip" do
      it "posts without a pow field even when difficulty > 0" do
        captured_body = nil
        stub_request(:post, "#{base_url}/kiosk/agents/register")
          .with { |req| captured_body = JSON.parse(req.body); true }
          .to_return(status: 201, body: register_body, headers: { "Content-Type" => "application/json" })

        client.register!(name: "skip-pow-agent", pow_difficulty: 20, pow: :skip)

        expect(captured_body).not_to have_key("pow")
      end
    end

    it "raises RegistrationError on non-201" do
      stub_request(:post, "#{base_url}/kiosk/agents/register")
        .to_return(status: 422, body: JSON.generate("error" => { "code" => "pow_required" }),
                   headers: { "Content-Type" => "application/json" })

      expect {
        client.register!(name: "bad-agent", pow: :skip)
      }.to raise_error(Kiosk::Redteam::Client::RegistrationError, /expected 201, got 422/)
    end

    it "posts name, public_key, and role in the request body" do
      captured_body = nil
      stub_request(:post, "#{base_url}/kiosk/agents/register")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 201, body: register_body, headers: { "Content-Type" => "application/json" })

      client.register!(name: "hermes", role: "customer")

      expect(captured_body["name"]).to eq("hermes")
      expect(captured_body["role"]).to eq("customer")
      expect(captured_body["public_key"]).to match(/BEGIN PUBLIC KEY/)
    end
  end

  # ── sign_mandate ─────────────────────────────────────────────────────────

  describe "#sign_mandate" do
    let(:rsa_key)   { OpenSSL::PKey::RSA.generate(2048) }
    let(:principal) do
      Kiosk::Redteam::Principal.new(
        agent_id: "a1", user_id: "u1", token: "tok", rsa_key:
      )
    end

    it "returns a compact JWS string (three dot-separated segments)" do
      jws = client.sign_mandate(principal, { "foo" => "bar" })
      expect(jws.split(".").length).to eq(3)
    end

    it "encodes claims that can be decoded back with the principal's public key" do
      claims = { "user_id" => "u1", "scope" => "mobility", "exp" => Time.now.to_i + 600 }
      jws = client.sign_mandate(principal, claims)

      decoded, header = JWT.decode(jws, rsa_key.public_key, true, { algorithm: "RS256" })
      expect(header["alg"]).to eq("RS256")
      expect(decoded["user_id"]).to eq("u1")
      expect(decoded["scope"]).to eq("mobility")
    end

    it "uses RS256 (not HS256 or none)" do
      jws = client.sign_mandate(principal, { "x" => 1 })
      # JWT header is base64url WITHOUT padding; compute exact padding required.
      segment = jws.split(".").first
      padded  = segment + ("=" * ((4 - segment.length % 4) % 4))
      header  = JSON.parse(Base64.urlsafe_decode64(padded))
      expect(header["alg"]).to eq("RS256")
    end

    it "produces a different JWS when given different claims" do
      jws1 = client.sign_mandate(principal, { "id" => "a" })
      jws2 = client.sign_mandate(principal, { "id" => "b" })
      expect(jws1).not_to eq(jws2)
    end

    it "signature verification fails with a different RSA key" do
      other_key = OpenSSL::PKey::RSA.generate(2048)
      jws = client.sign_mandate(principal, { "sub" => "u1" })

      expect {
        JWT.decode(jws, other_key.public_key, true, { algorithm: "RS256" })
      }.to raise_error(JWT::VerificationError)
    end
  end

  # ── kyc ─────────────────────────────────────────────────────────────────

  describe "#kyc" do
    let(:principal) do
      Kiosk::Redteam::Principal.new(agent_id: "a1", user_id: "u1", token: "bearer-tok", rsa_key: nil)
    end

    it "POSTs to /kiosk/agents/kyc with kyc_jws and Bearer token" do
      captured_req = nil
      stub_request(:post, "#{base_url}/kiosk/agents/kyc")
        .with { |req| captured_req = req; true }
        .to_return(status: 200, body: JSON.generate("ok" => true), headers: { "Content-Type" => "application/json" })

      resp = client.kyc(principal, attestation_jws: "fake.jws.token")

      expect(resp.status).to eq(200)
      expect(captured_req.headers["Authorization"]).to eq("Bearer bearer-tok")
      expect(JSON.parse(captured_req.body)["kyc_jws"]).to eq("fake.jws.token")
    end
  end

  # ── query ────────────────────────────────────────────────────────────────

  describe "#query" do
    let(:principal) do
      Kiosk::Redteam::Principal.new(agent_id: "a1", user_id: "u1", token: "tok-q", rsa_key: nil)
    end

    it "POSTs command=query with the given name and params" do
      captured_body = nil
      stub_request(:post, "#{base_url}/kiosk/exec")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 200, body: JSON.generate("rows" => []), headers: { "Content-Type" => "application/json" })

      client.query(principal, name: "my_orders", restaurant: "Foo")

      expect(captured_body["command"]).to eq("query")
      expect(captured_body["body"]["name"]).to eq("my_orders")
      expect(captured_body["body"]["restaurant"]).to eq("Foo")
    end
  end

  # ── run ──────────────────────────────────────────────────────────────────

  describe "#run" do
    let(:principal) do
      Kiosk::Redteam::Principal.new(agent_id: "a1", user_id: "u1", token: "tok-r", rsa_key: nil)
    end

    it "POSTs command=run with the given name and args" do
      captured_body = nil
      stub_request(:post, "#{base_url}/kiosk/exec")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 200, body: JSON.generate("value" => {}), headers: { "Content-Type" => "application/json" })

      client.run(principal, name: "place_order", quantity: 2)

      expect(captured_body["command"]).to eq("run")
      expect(captured_body["body"]["name"]).to eq("place_order")
      expect(captured_body["body"]["quantity"]).to eq(2)
    end
  end

  # ── pay ───────────────────────────────────────────────────────────────────

  describe "#pay" do
    let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
    let(:principal) do
      Kiosk::Redteam::Principal.new(agent_id: "ag1", user_id: "us1", token: "tok-p", rsa_key:)
    end

    it "POSTs command=pay with signed intent_mandate_jws and cart_mandate_jws" do
      captured_body = nil
      stub_request(:post, "#{base_url}/kiosk/exec")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 200, body: JSON.generate("value" => { "payment_mandate_id" => "pm1" }),
                   headers: { "Content-Type" => "application/json" })

      now = Time.now.to_i
      intent = { "id" => "i1", "user_id" => "us1", "scope" => "food", "exp" => now + 600, "iat" => now }
      cart   = { "id" => "c1", "intent_mandate_id" => "i1", "user_id" => "us1", "exp" => now + 600, "iat" => now }

      resp = client.pay(principal, intent:, cart:)

      expect(resp.status).to eq(200)
      expect(captured_body["command"]).to eq("pay")

      intent_jws = captured_body.dig("body", "intent_mandate_jws")
      cart_jws   = captured_body.dig("body", "cart_mandate_jws")

      expect(intent_jws).not_to be_nil
      expect(cart_jws).not_to be_nil

      # Both JWS must decode with the principal's public key
      decoded_intent, _ = JWT.decode(intent_jws, rsa_key.public_key, true, { algorithm: "RS256" })
      decoded_cart,   _ = JWT.decode(cart_jws,   rsa_key.public_key, true, { algorithm: "RS256" })

      expect(decoded_intent["id"]).to eq("i1")
      expect(decoded_cart["id"]).to eq("c1")
    end
  end

  # ── Response body parsing ─────────────────────────────────────────────────

  describe "Response body" do
    it "returns an empty hash when the response body is not valid JSON" do
      stub_request(:post, "#{base_url}/kiosk/agents/register")
        .to_return(status: 500, body: "Internal Server Error", headers: {})

      result = client.register_raw(name: "err-agent")
      expect(result.status).to eq(500)
      expect(result.body).to eq({})
    end
  end

  private

  # Helper used in PoW verification specs.
  def count_leading_zero_bits(bytes)
    return 0 if bytes.empty?
    count = 0
    bytes.each_byte do |b|
      if b == 0
        count += 8
      else
        bit = 7
        bit -= 1 while bit >= 0 && b[bit] == 0
        count += (7 - bit)
        break
      end
    end
    count
  end
end
