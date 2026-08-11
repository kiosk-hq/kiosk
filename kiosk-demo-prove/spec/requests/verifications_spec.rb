# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# Exercises the broker's security model (design §4) end to end over HTTP:
# intake auth + allow-list, unguessable capability, single-use, TTL, the signed
# anonymized per-request/operator/subject claim, and the SSRF/open-relay guard.
RSpec.describe "prove.my broker", type: :request do
  let(:operator_secret) { OperatorRegistry.registry["skooti"][:secret] }
  let(:callback_url)    { "http://127.0.0.1:3004/kyc/callback" }
  let(:intake_headers)  { { "Authorization" => "Bearer #{operator_secret}", "Content-Type" => "application/json" } }

  def intake(body, headers: intake_headers)
    post "/verifications", params: body.to_json, headers: headers
  end

  def valid_intake_body(overrides = {})
    {
      operator_id:      "skooti",
      callback_url:     callback_url,
      requested_claims: ["age_over_18", "licence_category:A"],
      subject_handle:   "user-uuid-123",
    }.merge(overrides)
  end

  describe "POST /verifications (intake)" do
    it "creates a pending request and returns a verification_url carrying the token" do
      intake(valid_intake_body)
      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("pending")
      expect(json["request_id"]).to be_present
      expect(json["verification_url"]).to include("/verify?request=#{json["request_id"]}")
      # The nonce is returned to the operator at intake (callback anti-replay)
      # but not exposed on the human page.
      expect(json["nonce"]).to be_present

      row = ProveRequest.find(json["request_id"])
      expect(json["nonce"]).to eq(row.nonce)
      expect(row.operator_id).to eq("skooti")
      expect(row.subject_handle).to eq("user-uuid-123")
      expect(row.status).to eq("pending")
      expect(row.nonce).to be_present
      expect(row.expires_at).to be > Time.current
    end

    it "rejects an unknown operator / bad secret (401) — a stranger cannot open requests" do
      intake(valid_intake_body, headers: { "Authorization" => "Bearer wrong", "Content-Type" => "application/json" })
      expect(response).to have_http_status(:unauthorized)
      expect(ProveRequest.count).to eq(0)
    end

    it "rejects a callback_url whose host is NOT allow-listed (SSRF/open-relay guard, 403)" do
      intake(valid_intake_body(callback_url: "http://evil.example.com/steal"))
      expect(response).to have_http_status(:forbidden)
      expect(ProveRequest.count).to eq(0)
    end

    it "rejects unknown/empty requested_claims (400)" do
      intake(valid_intake_body(requested_claims: ["not_a_claim"]))
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a missing subject_handle (400)" do
      intake(valid_intake_body(subject_handle: ""))
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an operator requesting ANOTHER operator's audience (cross-operator forgery, K-550)" do
      # Operator B (getgrocery) authenticates with its OWN bearer secret but asks
      # the broker to stamp operator A's (skooti's) audience into the attestation,
      # delivered to B's own callback. The broker derives `aud` from B's
      # REGISTRATION and rejects the mismatched body audience — B can never obtain
      # a skooti-audience ProveKey-signed claim (the cross-operator claim the wire
      # aud-check exists to stop). Pre-fix this stamped `aud: skooti` verbatim.
      gg_secret = OperatorRegistry.registry["getgrocery"][:secret]
      gg_headers = { "Authorization" => "Bearer #{gg_secret}", "Content-Type" => "application/json" }
      intake(
        {
          operator_id:      "getgrocery",
          callback_url:     "http://127.0.0.1/kyc/callback",
          requested_claims: ["age_over_18"],
          subject_handle:   "victim-subject",
          audience:         "skooti", # operator A's audience — must be refused
        },
        headers: gg_headers,
      )
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to match(/audience/)
      expect(ProveRequest.count).to eq(0)
    end
  end

  describe "GET /verify (human page)" do
    it "shows the yes/no questions for a live request" do
      intake(valid_intake_body)
      rid = JSON.parse(response.body)["request_id"]
      get "/verify", params: { request: rid }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("over 18")
      expect(response.body).to include("category A")
    end

    it "does not reveal anything for an unknown token" do
      get "/verify", params: { request: "not-a-real-token" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("not recognised")
    end
  end

  describe "POST /verify approve (mint + bind + single-use)" do
    def open_request(overrides = {})
      intake(valid_intake_body(overrides))
      JSON.parse(response.body)["request_id"]
    end

    def decode(jws)
      key = OpenSSL::PKey::RSA.new(ProveKey.public_key)
      JWT.decode(jws, key, true, algorithms: ["RS256"], required_claims: ["exp", "iss", "sub"]).first
    end

    it "mints a signed claim bound to (subject + operator + request) and echoes the nonce" do
      rid = open_request
      row = ProveRequest.find(rid)

      # The broker POSTs to the callback; stub the poster so no real host is hit,
      # and capture the delivered jws.
      delivered = {}
      allow(CallbackPoster).to receive(:deliver) do |args|
        delivered = args
        200
      end

      post "/verify", params: { request: rid, decision: "approve" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Confirmed")

      payload = decode(delivered[:kyc_jws])
      expect(payload["sub"]).to eq(row.subject_handle)
      expect(payload["iss"]).to eq(ProveKey.issuer)
      expect(payload["level"]).to eq("verified")
      expect(payload["operator"]).to eq("skooti")
      expect(payload["aud"]).to eq("skooti")
      expect(payload["request_id"]).to eq(rid)
      expect(payload["nonce"]).to eq(row.nonce)
      expect(payload["attributes"]).to eq({ "age_over_18" => true, "licence_a" => true })

      expect(delivered[:nonce]).to eq(row.nonce)
      expect(delivered[:callback_url]).to eq(callback_url)
      expect(row.reload.status).to eq("confirmed")
    end

    it "binds aud to the operator's REGISTERED audience, accepting a matching body declaration (K-550)" do
      # The honest operator sends its own kyc_audience (== its registered audience)
      # in the intake body; the broker bind-AND-verifies it against the operator's
      # registration record and stamps THAT as `aud` — the value the operator's
      # engine KycVerifier compares against, so a claim minted for operator A is
      # rejected at operator B.
      rid = open_request(audience: "skooti")
      row = ProveRequest.find(rid)
      expect(row.audience).to eq("skooti")

      delivered = {}
      allow(CallbackPoster).to receive(:deliver) { |args| delivered = args; 200 }
      post "/verify", params: { request: rid, decision: "approve" }

      payload = decode(delivered[:kyc_jws])
      expect(payload["aud"]).to eq("skooti")
      # operator handle is retained separately for callback correlation/logging
      expect(payload["operator"]).to eq("skooti")
    end

    it "mints aud from the registration even when the body declares no audience (aud == operator_id)" do
      rid = open_request # no audience in the body
      # The row records the registration-derived audience, never a raw body value.
      expect(ProveRequest.find(rid).audience).to eq("skooti")
      delivered = {}
      allow(CallbackPoster).to receive(:deliver) { |args| delivered = args; 200 }
      post "/verify", params: { request: rid, decision: "approve" }
      expect(decode(delivered[:kyc_jws])["aud"]).to eq("skooti")
    end

    it "grants ONLY the attributes the operator asked for (age_over_18 alone)" do
      rid = open_request(requested_claims: ["age_over_18"])
      delivered = {}
      allow(CallbackPoster).to receive(:deliver) { |args| delivered = args; 200 }
      post "/verify", params: { request: rid, decision: "approve" }
      payload = decode(delivered[:kyc_jws])
      expect(payload["attributes"]).to eq({ "age_over_18" => true })
    end

    # The catalog is the UNION the shared issuer can answer, not the set the
    # demos happen to use (design §1.1). `age_over_21` is the entry no shipped
    # operator requests; asking for it must work exactly like the ones that do,
    # question page included — that is what makes it an extension point rather
    # than dead surface (K-599).
    it "answers a catalog claim no shipped operator requests (age_over_21)" do
      rid = open_request(requested_claims: ["age_over_21"])

      get "/verify", params: { request: rid }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("over 21")

      delivered = {}
      allow(CallbackPoster).to receive(:deliver) { |args| delivered = args; 200 }
      post "/verify", params: { request: rid, decision: "approve" }

      expect(decode(delivered[:kyc_jws])["attributes"]).to eq({ "age_over_21" => true })
    end

    it "is single-use: a second approve on a confirmed request is rejected (no re-mint)" do
      rid = open_request
      allow(CallbackPoster).to receive(:deliver).and_return(200)
      post "/verify", params: { request: rid, decision: "approve" }
      expect(ProveRequest.find(rid).status).to eq("confirmed")

      expect(CallbackPoster).not_to receive(:deliver)
      post "/verify", params: { request: rid, decision: "approve" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "is un-confirmable once past its TTL" do
      rid = open_request
      ProveRequest.find(rid).update!(expires_at: 1.hour.ago)
      expect(CallbackPoster).not_to receive(:deliver)
      post "/verify", params: { request: rid, decision: "approve" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "records a decline without minting" do
      rid = open_request
      expect(CallbackPoster).not_to receive(:deliver)
      post "/verify", params: { request: rid, decision: "decline" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Declined")
      expect(ProveRequest.find(rid).status).to eq("declined")
    end
  end

  describe "GET /prove_key.pem" do
    it "serves the ProveKey public PEM operators pin" do
      get "/prove_key.pem"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("PUBLIC KEY")
    end
  end
end
