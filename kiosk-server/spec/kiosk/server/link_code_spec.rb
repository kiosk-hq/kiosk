# frozen_string_literal: true

require "openssl"

# The link half of the ceremony (Kiosk extension). Binding is
# stubbed (account_binding_spec.rb covers it); the possession proof uses a
# REAL key so the BIND-POP gate is exercised end-to-end at this layer.
RSpec.describe Kiosk::Server::LinkCode do
  let(:store)   { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }
  let(:rsa)     { OpenSSL::PKey::RSA.generate(2048) }
  let(:pem)     { rsa.public_key.to_pem }

  before do
    Kiosk.configure do |c|
      c.issuer                     = "https://combette.example"
      c.roles                      = %i[customer]
      c.device_authorization_store = store
    end
  end

  # Register-shaped possession proof: fetch a challenge for the key, sign
  # {aud, nonce, jti} with the private half.
  def signed_proof(aud: "https://combette.example")
    challenge = Kiosk::Server::AuthChallenge.issue(public_key_pem: pem)
    JWT.encode(
      { aud: aud, nonce: challenge[:challenge], jti: SecureRandom.uuid },
      rsa, "RS256",
    )
  end

  def stub_binding
    allow(Kiosk::Server::AccountBinding).to receive(:bind!).and_return(
      { agent_id: "agent-1", user_id: user_id, access_token: "kiosk-pop-jwt", fresh: true },
    )
  end

  describe ".mint" do
    it "creates a pre-approved :link row bound to the holder and returns the plain code" do
      result = described_class.mint(user_id: user_id)

      expect(result[:link_code]).to be_a(String)
      expect(result[:expires_in]).to eq(Kiosk::Server::DeviceAuthorization::DEFAULT_EXPIRES_IN)
      expect(result[:da]).to be_approved
      expect(result[:da]).to be_link
      expect(result[:da].user_id).to eq(user_id)
      expect(result[:da].client_id).to eq(described_class::CLIENT_ID)
    end

    it "persists only the hash of the link code" do
      result = described_class.mint(user_id: user_id)
      stored = store.find_by_device_code_hash(
        Kiosk::Server::DeviceAuthorization.hash_device_code(result[:link_code]),
      )
      expect(stored).to eq(result[:da])
    end

    # roles-from-IdP (Path A): the human's role travels on the link
    # row so the assistant inherits it at claim time.
    it "stamps the human's requested_role onto the link row (roles-from-IdP)" do
      Kiosk.configure { |c| c.roles = %i[customer owner] }
      result = described_class.mint(user_id: user_id, requested_role: "owner")
      expect(result[:da].requested_role).to eq("owner")
    end

    it "leaves requested_role nil for a role-less human (no regression)" do
      result = described_class.mint(user_id: user_id)
      expect(result[:da].requested_role).to be_nil
    end
  end

  describe ".redeem" do
    let(:code) { described_class.mint(user_id: user_id)[:link_code] }

    it "binds the presented key with a valid proof and consumes the code (single-use)" do
      stub_binding
      result = described_class.redeem(code: code, public_key_pem: pem, signed: signed_proof)

      expect(result).to eq(agent_id: "agent-1", user_id: user_id, access_token: "kiosk-pop-jwt")
      # The PEM is normalised (stripped) before binding.
      expect(Kiosk::Server::AccountBinding).to have_received(:bind!).with(
        public_key_pem: pem.strip, user_id: user_id, requested_role: nil,
      )

      # Second redeem → conflict (single-use).
      expect {
        described_class.redeem(code: code, public_key_pem: pem, signed: signed_proof)
      }.to raise_error(Kiosk::Server::Errors::Conflict, /already used/)
    end

    it "forwards the row's captured requested_role to AccountBinding.bind! (roles-from-IdP)" do
      Kiosk.configure { |c| c.roles = %i[customer owner] }
      stub_binding
      role_code = described_class.mint(user_id: user_id, requested_role: "owner")[:link_code]

      described_class.redeem(code: role_code, public_key_pem: pem, signed: signed_proof)
      expect(Kiosk::Server::AccountBinding).to have_received(:bind!).with(
        public_key_pem: pem.strip, user_id: user_id, requested_role: "owner",
      )
    end

    it "raises Unauthenticated on a failed proof and does NOT consume the code" do
      stub_binding
      other_key = OpenSSL::PKey::RSA.generate(2048)
      challenge = Kiosk::Server::AuthChallenge.issue(public_key_pem: pem)
      forged = JWT.encode(
        { aud: "https://combette.example", nonce: challenge[:challenge], jti: "x" },
        other_key, "RS256",
      )

      expect {
        described_class.redeem(code: code, public_key_pem: pem, signed: forged)
      }.to raise_error(Kiosk::Server::Errors::Unauthenticated)
      expect(Kiosk::Server::AccountBinding).not_to have_received(:bind!)

      # The rightful key holder can still redeem.
      expect(
        described_class.redeem(code: code, public_key_pem: pem, signed: signed_proof),
      ).to include(agent_id: "agent-1")
    end

    it "raises Unauthenticated on an origin-mismatched proof (relay defense)" do
      stub_binding
      expect {
        described_class.redeem(
          code: code, public_key_pem: pem,
          signed: signed_proof(aud: "https://evil.example"),
        )
      }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /audience/)
    end

    it "raises BadRequest for an undersized key (same floor as registration)" do
      small = OpenSSL::PKey::RSA.generate(1024)
      expect {
        described_class.redeem(code: code, public_key_pem: small.public_key.to_pem, signed: "x")
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /too small/)
    end

    it "raises NotFound for an unknown code" do
      expect {
        described_class.redeem(code: "no-such-code", public_key_pem: pem, signed: "x")
      }.to raise_error(Kiosk::Server::Errors::NotFound, /unknown link code/)
    end

    it "raises BadRequest for a blank code" do
      expect {
        described_class.redeem(code: "", public_key_pem: pem, signed: "x")
      }.to raise_error(Kiosk::Server::Errors::BadRequest, /code required/)
    end

    it "raises NotFound for an expired code (and bumps the row lazily)" do
      minted = described_class.mint(user_id: user_id)
      expect {
        described_class.redeem(
          code: minted[:link_code], public_key_pem: pem, signed: "x",
          now: minted[:da].expires_at + 1,
        )
      }.to raise_error(Kiosk::Server::Errors::NotFound, /expired/)
      expect(
        store.find_by_device_code_hash(minted[:da].device_code_hash),
      ).to be_expired
    end

    it "refuses to redeem a claim-flow device_code (kinds do not cross)" do
      claim = Kiosk::Server::DeviceCodeGrant.start(client_id: "cli", public_key_pem: pem)
      expect {
        described_class.redeem(code: claim[:device_code], public_key_pem: pem, signed: "x")
      }.to raise_error(Kiosk::Server::Errors::NotFound, /unknown link code/)
    end
  end
end
