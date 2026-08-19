# frozen_string_literal: true

require "spec_helper"
require "base64"
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
      stub_request(:post, "#{base_url}/kiosk/auth/register")
        .to_return(status: 201, body: register_body, headers: { "Content-Type" => "application/json" })

      result = client.register_raw(name: "test-agent")
      expect(result).to be_a(Kiosk::Redteam::Response)
      expect(result.status).to eq(201)
    end

    context "when pow: :skip" do
      it "posts without a pow field" do
        req_stub = stub_request(:post, "#{base_url}/kiosk/auth/register")
          .to_return(problem_return("pow_required"))

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
      it "sends that exact string as the Kiosk-PoW header value (ADR-0022)" do
        captured_header = nil
        captured_body   = nil
        stub_request(:post, "#{base_url}/kiosk/auth/register")
          .with { |req| captured_header = req.headers["Kiosk-Pow"]; captured_body = JSON.parse(req.body); true }
          .to_return(problem_return("bad_request"))

        client.register_raw(name: "bad-pow-agent", pow_difficulty: 20, pow: "definitely_wrong_proof")

        expect(captured_header).to eq("definitely_wrong_proof")
        expect(captured_body).not_to have_key("pow")  # proof is in the header, not the body
      end
    end
  end

  # ── register! ───────────────────────────────────────────────────────────

  describe "#register!" do
    context "with pow_difficulty: 0 (no PoW required)" do
      it "posts without a pow field and returns a Principal" do
        captured_body = nil
        stub_request(:post, "#{base_url}/kiosk/auth/register")
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

    context "when the provider gates registration with Equihash (402)" do
      it "solves the challenge and resubmits with the proof in the Kiosk-PoW header (ADR-0022)" do
        # First register → 402 with a KAT challenge (n=8,k=1); the client solves
        # it with the real solver and resubmits. Second register → 201.
        kat_challenge = { "id" => "c1", "alg" => "equihash", "params" => { "n" => 8, "k" => 1 },
                          "salt" => Base64.strict_encode64("kat"), "exp" => 9_999_999_999, "sig" => "x" }
        bodies      = []
        pow_headers = []
        calls  = 0
        stub_request(:post, "#{base_url}/kiosk/auth/register")
          .with { |req| bodies << JSON.parse(req.body); pow_headers << req.headers["Kiosk-Pow"]; true }
          .to_return do
            calls += 1
            if calls == 1
              # RFC 9457: `challenges` is a TOP-LEVEL extension member of the
              # problem document — Client#build_register reads it there, not
              # off a nested `error` object.
              problem_return("pow_required", challenges: [kat_challenge])
            else
              { status: 201, body: register_body, headers: { "Content-Type" => "application/json" } }
            end
          end

        principal = client.register!(name: "pow-agent", pow_difficulty: 1, pow: :solve)

        expect(principal.token).to eq("tok-abc")
        expect(bodies.first).not_to have_key("pow")            # first attempt: no proof
        expect(pow_headers.first).to be_nil                    # first attempt: no header
        expect(bodies.last).not_to have_key("pow")             # resubmit: proof NOT in body
        proofs = JSON.parse(pow_headers.last)                  # resubmit: proof in the header
        expect(proofs).to be_an(Array)
        expect(proofs.first["nonce"]).to include("indices")
      end
    end

    context "when the 402 gate carries no solvable challenges" do
      it "does NOT resubmit and surfaces the 402 as a RegistrationError" do
        # A 402 problem document with no `challenges` member: the client
        # cannot solve anything, so it must post exactly once (no resubmit)
        # and register! must raise on the still-402 response.
        calls = 0
        stub_request(:post, "#{base_url}/kiosk/auth/register")
          .to_return do
            calls += 1
            problem_return("pow_required")
          end

        expect {
          client.register!(name: "no-challenges-agent", pow_difficulty: 1, pow: :solve)
        }.to raise_error(Kiosk::Redteam::Client::RegistrationError, /expected 201, got 402/)

        # Exactly one POST — the solve/resubmit branch was NOT taken.
        expect(calls).to eq(1)
      end
    end

    context "with pow: :skip" do
      it "posts without a pow field even when difficulty > 0" do
        captured_body = nil
        stub_request(:post, "#{base_url}/kiosk/auth/register")
          .with { |req| captured_body = JSON.parse(req.body); true }
          .to_return(status: 201, body: register_body, headers: { "Content-Type" => "application/json" })

        client.register!(name: "skip-pow-agent", pow_difficulty: 20, pow: :skip)

        expect(captured_body).not_to have_key("pow")
      end
    end

    it "raises RegistrationError on non-201" do
      stub_request(:post, "#{base_url}/kiosk/auth/register")
        .to_return(problem_return("bad_request", status: 422))

      expect {
        client.register!(name: "bad-agent", pow: :skip)
      }.to raise_error(Kiosk::Redteam::Client::RegistrationError, /expected 201, got 422/)
    end

    it "posts public_key and a proof-of-possession JWS (no name/role on the wire)" do
      captured_body = nil
      stub_request(:post, "#{base_url}/kiosk/auth/register")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 201, body: register_body, headers: { "Content-Type" => "application/json" })

      client.register!(name: "hermes", role: "customer")

      # name/role are pinned server-side now — they are not sent.
      expect(captured_body).not_to have_key("name")
      expect(captured_body).not_to have_key("role")
      expect(captured_body["signed"]).to be_a(String).and match(/\A[\w-]+\.[\w-]+\.[\w-]+\z/) # compact JWS
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
        .to_return(json_return(200, "kyc_verified" => true, "attributes" => {}))

      resp = client.kyc(principal, attestation_jws: "fake.jws.token")

      expect(resp.status).to eq(200)
      expect(captured_req.headers["Authorization"]).to eq("Bearer bearer-tok")
      expect(JSON.parse(captured_req.body)["kyc_jws"]).to eq("fake.jws.token")
    end
  end

  # ── query ────────────────────────────────────────────────────────────────
  #
  # These two describes are the ONLY place the wire shape of a verb call is
  # pinned, so they assert the request rather than the answer: the method, the
  # verb name as a PATH SEGMENT, the channel its arguments travel on, and that
  # `name` appears nowhere — it was 0.3's multiplexing field and the cutover
  # deleted the endpoints that read it.

  describe "#query" do
    let(:principal) do
      Kiosk::Redteam::Principal.new(agent_id: "a1", user_id: "u1", token: "tok-q", rsa_key: nil)
    end

    it "GETs /kiosk/<name> with the params in the query string (no body, no name field)" do
      captured_req = nil
      stub = stub_request(:get, "#{base_url}/kiosk/my_orders")
        .with(query: { "restaurant" => "Foo", "limit" => "5" })
        .with { |req| captured_req = req; true }
        .to_return(json_return(200, []))

      client.query(principal, name: "my_orders", restaurant: "Foo", limit: 5)

      expect(stub).to have_been_requested.once
      expect(captured_req.method).to eq(:get)
      expect(captured_req.uri.path).to eq("/kiosk/my_orders")
      # Every argument is a query-string pair, and the wire carries them as
      # strings — the origin recovers the declared types (ArgumentDecoder).
      expect(URI.decode_www_form(captured_req.uri.query).to_h)
        .to eq("restaurant" => "Foo", "limit" => "5")
      expect(captured_req.headers["Authorization"]).to eq("Bearer tok-q")
      # A GET has no body — and there is nowhere left for a `name` to ride.
      expect(captured_req.body.to_s).to eq("")
      expect(captured_req.uri.to_s).not_to include("name=")
      expect(captured_req.uri.path).not_to include("/query")
    end

    it "GETs the bare verb path when there are no params at all" do
      stub = stub_request(:get, "#{base_url}/kiosk/my_orders").to_return(json_return(200, []))

      client.query(principal, name: "my_orders")

      expect(stub).to have_been_requested.once
    end

    it "reads a non-paginating query's BARE ARRAY answer as the body" do
      stub_request(:get, "#{base_url}/kiosk/my_orders")
        .to_return(json_return(200, [{ "id" => "r1" }]))

      resp = client.query(principal, name: "my_orders")

      expect(resp.status).to eq(200)
      expect(resp.body).to eq([{ "id" => "r1" }])
    end
  end

  # ── run ──────────────────────────────────────────────────────────────────

  describe "#run" do
    let(:principal) do
      Kiosk::Redteam::Principal.new(agent_id: "a1", user_id: "u1", token: "tok-r", rsa_key: nil)
    end

    it "POSTs /kiosk/<name> with the args as the WHOLE body (no name field)" do
      captured_req = nil
      stub = stub_request(:post, "#{base_url}/kiosk/place_order")
        .with { |req| captured_req = req; true }
        .to_return(json_return(200, "order_id" => "o1"))

      client.run(principal, name: "place_order", quantity: 2, sku: "SK-1")

      expect(stub).to have_been_requested.once
      expect(captured_req.method).to eq(:post)
      expect(captured_req.uri.path).to eq("/kiosk/place_order")
      expect(captured_req.uri.query).to be_nil
      expect(captured_req.headers["Authorization"]).to eq("Bearer tok-r")

      body = JSON.parse(captured_req.body)
      # The body IS the arguments — nothing else is in it.
      expect(body).to eq("quantity" => 2, "sku" => "SK-1")
      expect(body).not_to have_key("name")
      expect(body).not_to have_key("command")
      expect(captured_req.uri.path).not_to include("/run")
    end

    it "POSTs an empty JSON object when the action takes no arguments" do
      captured_body = nil
      stub_request(:post, "#{base_url}/kiosk/close_tab")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(json_return(200, "closed" => true))

      client.run(principal, name: "close_tab")

      expect(captured_body).to eq({})
    end

    it "reads an action's own object as the body — there is no envelope" do
      stub_request(:post, "#{base_url}/kiosk/place_order")
        .to_return(json_return(200, "order_id" => "o1", "total_cents" => 900))

      resp = client.run(principal, name: "place_order")

      expect(resp.body).to eq("order_id" => "o1", "total_cents" => 900)
    end
  end

  # ── pay ───────────────────────────────────────────────────────────────────

  describe "#pay" do
    let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
    let(:principal) do
      Kiosk::Redteam::Principal.new(agent_id: "ag1", user_id: "us1", token: "tok-p", rsa_key:)
    end

    it "POSTs to /kiosk/pay with signed intent_mandate_jws and cart_mandate_jws" do
      captured_body = nil
      stub_request(:post, "#{base_url}/kiosk/pay")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(json_return(200, "settlement_id" => "stl-1", "psp_reference" => "pi_1",
                                    "settled_amount_cents" => 100, "currency" => "eur"))

      now = Time.now.to_i
      intent = { "id" => "i1", "user_id" => "us1", "scope" => "food", "exp" => now + 600, "iat" => now }
      cart   = { "id" => "c1", "intent_mandate_id" => "i1", "user_id" => "us1", "exp" => now + 600, "iat" => now }

      resp = client.pay(principal, intent:, cart:)

      expect(resp.status).to eq(200)
      expect(captured_body).not_to have_key("command")

      intent_jws = captured_body["intent_mandate_jws"]
      cart_jws   = captured_body["cart_mandate_jws"]

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
      stub_request(:post, "#{base_url}/kiosk/auth/register")
        .to_return(status: 500, body: "Internal Server Error", headers: {})

      result = client.register_raw(name: "err-agent")
      expect(result.status).to eq(500)
      expect(result.body).to eq({})
    end
  end
end
