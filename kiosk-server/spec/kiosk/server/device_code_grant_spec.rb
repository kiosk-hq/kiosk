# frozen_string_literal: true

RSpec.describe Kiosk::Server::DeviceCodeGrant do
  let(:store) { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:rsa)   { OpenSSL::PKey::RSA.generate(2048) }
  let(:key)   { Kiosk::Server::SigningKey.new(rsa) }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }

  before do
    Kiosk.configure do |c|
      c.issuer                      = "https://combette.example/kiosk"
      c.signing_key                 = key
      c.device_authorization_store  = store
    end
  end

  describe ".start" do
    it "creates a pending row and returns the full /oauth/device_authorization payload" do
      result = described_class.start(client_id: "kiosk-cli", requested_role: "customer")

      expect(result.keys).to include(:device_code, :user_code, :expires_in, :interval, :da)
      expect(result[:device_code]).to be_a(String)
      expect(result[:user_code]).to match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
      expect(result[:expires_in]).to eq(Kiosk::Server::DeviceAuthorization::DEFAULT_EXPIRES_IN)
      expect(result[:interval]).to eq(described_class::DEFAULT_POLL_INTERVAL)
      expect(store.size).to eq(1)
      expect(result[:da]).to be_pending
    end

    it "persists the SHA-256 hash of the device_code (not plain)" do
      result = described_class.start(client_id: "kiosk-cli")
      stored = store.find_by_device_code_hash(
        Kiosk::Server::DeviceAuthorization.hash_device_code(result[:device_code]),
      )
      expect(stored).to eq(result[:da])
    end
  end

  describe ".exchange" do
    let(:start_result) { described_class.start(client_id: "kiosk-cli", requested_role: "customer") }
    let(:device_code)  { start_result[:device_code] }

    context "request validation" do
      it "rejects missing device_code with invalid_request" do
        result = described_class.exchange(device_code: nil)
        expect(result).to include(ok: false, error: "invalid_request")
      end

      it "rejects empty device_code with invalid_request" do
        result = described_class.exchange(device_code: "")
        expect(result).to include(ok: false, error: "invalid_request")
      end

      it "rejects unknown device_code with invalid_grant" do
        result = described_class.exchange(device_code: "definitely-not-a-real-code")
        expect(result).to include(ok: false, error: "invalid_grant")
      end
    end

    context "state-machine outcomes" do
      before { start_result } # materialise the pending row

      it "returns authorization_pending while the user has not acted" do
        result = described_class.exchange(device_code: device_code)
        expect(result).to include(ok: false, error: "authorization_pending")
      end

      it "returns access_denied when the user denied" do
        store.update(start_result[:da].deny)
        result = described_class.exchange(device_code: device_code)
        expect(result).to include(ok: false, error: "access_denied")
      end

      it "returns invalid_grant when the code was already consumed" do
        consumed = start_result[:da].approve(user_id: user_id).consume
        store.update(consumed)
        result = described_class.exchange(device_code: device_code)
        expect(result).to include(ok: false, error: "invalid_grant")
      end

      it "returns expired_token when expires_at has passed" do
        result = described_class.exchange(
          device_code: device_code,
          now:         start_result[:da].expires_at + 1,
        )
        expect(result).to include(ok: false, error: "expired_token")

        # And the row was bumped to :expired so subsequent polls see it.
        reloaded = store.find_by_device_code_hash(
          Kiosk::Server::DeviceAuthorization.hash_device_code(device_code),
        )
        expect(reloaded).to be_expired
      end

      it "issues a JWT and consumes the row when approved" do
        store.update(start_result[:da].approve(user_id: user_id))
        result = described_class.exchange(device_code: device_code)

        expect(result).to include(
          ok:         true,
          token_type: "Bearer",
          expires_in: Kiosk::Server::JwtIssuer::DEFAULT_EXPIRES_IN,
          scope:      "customer",
        )
        expect(result[:access_token]).to be_a(String)

        # Row is now consumed; second poll → invalid_grant.
        second = described_class.exchange(device_code: device_code)
        expect(second).to include(ok: false, error: "invalid_grant")
      end

      it "issued JWT verifies against the same SigningKey and carries the principal claims" do
        store.update(start_result[:da].approve(user_id: user_id))
        result = described_class.exchange(device_code: device_code)

        claims = Kiosk::Server::JwtIssuer.verify(
          token:    result[:access_token],
          jwks:     key,
          audience: "https://combette.example/kiosk",
        )
        expect(claims).to include(
          sub:       user_id,
          role:      "customer",
          client_id: "kiosk-cli",
        )
      end

      it "omits the scope/role from JWT and response when no role was requested" do
        # Restart with no role.
        start_result = described_class.start(client_id: "kiosk-cli")
        store.update(start_result[:da].approve(user_id: user_id))

        result = described_class.exchange(device_code: start_result[:device_code])
        expect(result.keys).not_to include(:scope)

        claims = Kiosk::Server::JwtIssuer.verify(
          token:    result[:access_token],
          jwks:     key,
          audience: "https://combette.example/kiosk",
        )
        expect(claims).not_to include(:role)
      end
    end
  end
end
