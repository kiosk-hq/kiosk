# frozen_string_literal: true

# The claim half of the account-binding ceremony (ADR-0017). Binding itself
# (fresh-register vs rebind) is covered in account_binding_spec.rb; here it
# is stubbed so the RFC 8628 state machine + BIND-POP gate can be exercised
# in isolation.
RSpec.describe Kiosk::Server::DeviceCodeGrant do
  let(:store) { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:pem)   { "-----BEGIN PUBLIC KEY-----\nMIIB...\n-----END PUBLIC KEY-----" }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }

  before do
    Kiosk.configure do |c|
      c.issuer                      = "https://combette.example/kiosk"
      c.device_authorization_store  = store
    end
    described_class.reset_poll_registry!
  end

  describe ".start" do
    it "creates a pending :claim row and returns the full /oauth/device_authorization payload" do
      result = described_class.start(
        client_id: "kiosk-cli", public_key_pem: pem, requested_role: "customer",
      )

      expect(result.keys).to include(:device_code, :user_code, :expires_in, :interval, :da)
      expect(result[:device_code]).to be_a(String)
      expect(result[:user_code]).to match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/)
      expect(result[:expires_in]).to eq(Kiosk::Server::DeviceAuthorization::DEFAULT_EXPIRES_IN)
      expect(result[:interval]).to eq(described_class::DEFAULT_POLL_INTERVAL)
      expect(store.size).to eq(1)
      expect(result[:da]).to be_pending
      expect(result[:da]).to be_claim
    end

    it "binds the presented public key to the row (normalised)" do
      result = described_class.start(client_id: "kiosk-cli", public_key_pem: "  #{pem}\n")
      expect(result[:da].public_key_pem).to eq(pem)
    end

    it "persists only hashes of both codes (not plain)" do
      result = described_class.start(client_id: "kiosk-cli", public_key_pem: pem)
      stored = store.find_by_device_code_hash(
        Kiosk::Server::DeviceAuthorization.hash_device_code(result[:device_code]),
      )
      expect(stored).to eq(result[:da])
      expect(stored.user_code_hash).to eq(
        Kiosk::Server::DeviceAuthorization.hash_user_code(result[:user_code].tr("-", "")),
      )
    end
  end

  describe ".exchange" do
    let(:start_result) {
      described_class.start(client_id: "kiosk-cli", public_key_pem: pem, requested_role: "customer")
    }
    let(:device_code) { start_result[:device_code] }

    # `interval: 0` disables the slow_down gate so state-machine examples
    # can poll back-to-back; the gate has its own examples below.
    def exchange(**kwargs)
      described_class.exchange(device_code: device_code, interval: 0, **kwargs)
    end

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

    context "slow_down (RFC 8628 §3.5)" do
      it "tells a client polling faster than the interval to back off" do
        start_result
        t0 = Time.now
        first  = described_class.exchange(device_code: device_code, now: t0)
        second = described_class.exchange(device_code: device_code, now: t0 + 1)
        expect(first).to include(error: "authorization_pending")
        expect(second).to include(ok: false, error: "slow_down")
      end

      it "serves a client honouring the interval normally" do
        start_result
        t0 = Time.now
        described_class.exchange(device_code: device_code, now: t0)
        third = described_class.exchange(
          device_code: device_code,
          now:         t0 + described_class::DEFAULT_POLL_INTERVAL + 1,
        )
        expect(third).to include(error: "authorization_pending")
      end
    end

    context "state-machine outcomes" do
      before { start_result } # materialise the pending row

      it "returns authorization_pending while the account holder has not acted" do
        expect(exchange).to include(ok: false, error: "authorization_pending")
      end

      it "returns access_denied when the account holder denied" do
        store.update(start_result[:da].deny)
        expect(exchange).to include(ok: false, error: "access_denied")
      end

      it "returns invalid_grant when the code was already consumed" do
        consumed = start_result[:da].approve(user_id: user_id).consume
        store.update(consumed)
        expect(exchange).to include(ok: false, error: "invalid_grant")
      end

      it "returns expired_token when expires_at has passed" do
        result = exchange(now: start_result[:da].expires_at + 1)
        expect(result).to include(ok: false, error: "expired_token")

        # And the row was bumped to :expired so subsequent polls see it.
        reloaded = store.find_by_device_code_hash(
          Kiosk::Server::DeviceAuthorization.hash_device_code(device_code),
        )
        expect(reloaded).to be_expired
      end
    end

    context "BIND-POP on an approved row" do
      before do
        start_result
        store.update(start_result[:da].approve(user_id: user_id))
      end

      it "returns invalid_client when the poll carries no signed proof — row NOT consumed" do
        result = exchange
        expect(result).to include(ok: false, error: "invalid_client")

        reloaded = store.find_by_device_code_hash(
          Kiosk::Server::DeviceAuthorization.hash_device_code(device_code),
        )
        expect(reloaded).to be_approved
      end

      it "returns invalid_client when the proof fails — row NOT consumed, retry allowed" do
        allow(Kiosk::Server::PopVerifier).to receive(:verify!)
          .and_raise(Kiosk::Server::Errors::Unauthenticated.new("proof signature invalid"))

        result = exchange(signed: "bad-jws")
        expect(result).to include(ok: false, error: "invalid_client")
        expect(result[:description]).to match(/proof signature invalid/)

        # The rightful key holder can still retry with a valid proof.
        allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return({ nonce: "n" })
        allow(Kiosk::Server::AuthChallenge).to receive(:consume!).and_return(true)
        allow(Kiosk::Server::AccountBinding).to receive(:bind!).and_return(
          { agent_id: "a-1", user_id: user_id, access_token: "tok", fresh: true },
        )
        expect(exchange(signed: "good-jws")).to include(ok: true)
      end

      it "returns invalid_client on a stale/missing challenge nonce — row NOT consumed" do
        allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return({ nonce: "n" })
        allow(Kiosk::Server::AuthChallenge).to receive(:consume!)
          .and_raise(Kiosk::Server::Errors::Unauthenticated.new("no matching auth challenge"))

        result = exchange(signed: "jws")
        expect(result).to include(ok: false, error: "invalid_client")
        reloaded = store.find_by_device_code_hash(
          Kiosk::Server::DeviceAuthorization.hash_device_code(device_code),
        )
        expect(reloaded).to be_approved
      end

      context "with a valid proof" do
        before do
          allow(Kiosk::Server::PopVerifier).to receive(:verify!).and_return({ nonce: "n" })
          allow(Kiosk::Server::AuthChallenge).to receive(:consume!).and_return(true)
          allow(Kiosk::Server::AccountBinding).to receive(:bind!).and_return(
            { agent_id: "a-1", user_id: user_id, access_token: "kiosk-pop-jwt", fresh: true },
          )
        end

        it "verifies the proof against the ROW's key, not anything client-supplied" do
          exchange(signed: "jws")
          expect(Kiosk::Server::PopVerifier).to have_received(:verify!)
            .with(public_key_pem: pem, signed: "jws")
          expect(Kiosk::Server::AuthChallenge).to have_received(:consume!)
            .with(public_key_pem: pem, nonce: "n")
        end

        it "binds the row's key to the approving holder's account and consumes the row" do
          result = exchange(signed: "jws")

          expect(Kiosk::Server::AccountBinding).to have_received(:bind!).with(
            public_key_pem: pem, user_id: user_id, requested_role: "customer",
          )
          expect(result).to include(
            ok:           true,
            access_token: "kiosk-pop-jwt",
            token_type:   "Bearer",
            expires_in:   Kiosk::Server::JwtIssuer::DEFAULT_EXPIRES_IN,
            scope:        "customer",
          )

          # Row is now consumed; second poll → invalid_grant (single-use).
          expect(exchange(signed: "jws")).to include(ok: false, error: "invalid_grant")
        end

        it "omits scope when no role was requested" do
          bare = described_class.start(client_id: "kiosk-cli", public_key_pem: pem)
          store.update(bare[:da].approve(user_id: user_id))

          result = described_class.exchange(
            device_code: bare[:device_code], signed: "jws", interval: 0,
          )
          expect(result[:ok]).to be(true)
          expect(result.keys).not_to include(:scope)
        end
      end
    end
  end
end
