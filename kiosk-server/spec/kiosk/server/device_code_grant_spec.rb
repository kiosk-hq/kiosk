# frozen_string_literal: true

# The claim ceremony on the RFC 8628 wire, below the controllers: the row a
# client opens, and each outcome of a poll by that client.
RSpec.describe Kiosk::Server::DeviceCodeGrant do
  include_context 'with registered clients'

  let(:store)  { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:client) { register_client }
  let(:holder) { holder! }
  let(:start)  { described_class.start(client: client, store: store) }

  before { described_class.reset_poll_registry! }

  def exchange(device_code: start[:device_code], client: self.client, **)
    described_class.exchange(device_code: device_code, client: client, store: store, interval: 0, **)
  end

  def expect_refused(error, &)
    expect(&).to raise_error(Kiosk::Server::OauthError) { |e| expect(e.code).to eq(error) }
  end

  def approve(role: 'owner') = store.update(start[:da].approve(user_id: holder, role: role))

  describe '.start' do
    it 'creates a pending :claim row for the client, with its key, and the /oauth/device_authorization payload' do
      expect(start).to include(device_code: be_a(String), user_code: match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/),
                               expires_in: Kiosk::Server::DeviceAuthorization::DEFAULT_EXPIRES_IN,
                               interval: described_class::DEFAULT_POLL_INTERVAL)
      expect(start[:da]).to be_pending.and be_claim
      expect([start[:da].client_id, start[:da].public_key_pem]).to eq([client.id, client.public_key_pem])
    end

    # K-072: the role is stamped at APPROVAL, from the approving human.
    it 'creates the row ROLE-LESS and accepts no role parameter' do
      expect(start[:da].requested_role).to be_nil
      expect { described_class.start(client: client, store: store, requested_role: 'owner') }
        .to raise_error(ArgumentError, /unknown keyword: :requested_role/)
    end

    it 'persists only hashes of both codes' do
      stored = store.lookup_by_device_code_hash(Kiosk::Server::DeviceAuthorization.hash_device_code(start[:device_code]))
      expect(stored).to eq(start[:da])
      expect(stored.user_code_hash).to eq(Kiosk::Server::DeviceAuthorization.hash_user_code(start[:user_code].tr('-', '')))
    end
  end

  describe '.exchange' do
    it 'refuses an unknown device_code, and a link code, with invalid_grant' do
      expect_refused('invalid_grant') { exchange(device_code: 'definitely-not-a-real-code') }
      link = Kiosk::Server::LinkCode.mint(user_id: holder, store: store)[:link_code]
      expect_refused('invalid_grant') { exchange(device_code: link) }
    end

    it 'refuses a device_code opened by another client with invalid_grant' do
      start
      expect_refused('invalid_grant') { exchange(client: register_client(other_key)) }
    end

    it 'answers authorization_pending and access_denied, the RFC 8628 codes' do
      expect_refused('authorization_pending') { exchange }
      store.update(start[:da].deny)
      expect_refused('access_denied') { exchange }
    end

    it 'answers expired_token after expires_at, and marks the row expired' do
      start
      expect_refused('expired_token') { exchange(now: start[:da].expires_at + 1) }
      expect(store.lookup_by_device_code_hash(start[:da].device_code_hash)).to be_expired
    end

    it 'tells a client that polls faster than the interval to slow down' do
      t0 = Time.current
      expect_refused('authorization_pending') { described_class.exchange(device_code: start[:device_code], client: client, store: store, now: t0) }
      expect_refused('slow_down') { described_class.exchange(device_code: start[:device_code], client: client, store: store, now: t0 + 1) }
      expect_refused('authorization_pending') do
        described_class.exchange(device_code: start[:device_code], client: client, store: store,
                                 now: t0 + described_class::DEFAULT_POLL_INTERVAL + 2)
      end
    end

    it "binds the client to the approving holder with the holder's role, and consumes the row" do
      approve
      bound = exchange

      expect([bound.id, bound.user_id, bound.role]).to eq([client.id, holder, 'owner'])
      expect(store.lookup_by_device_code_hash(start[:da].device_code_hash)).to be_consumed
      expect_refused('invalid_grant') { exchange }
    end

    # K-887: two concurrent polls both read the approved row; the atomic
    # consume lets one bind.
    it 'binds for only ONE of two concurrent polls of the same device_code' do
      approved = start[:da].approve(user_id: holder, role: 'owner')
      store.update(approved)
      allow(store).to receive(:lookup_by_device_code_hash).and_return(approved)
      allow(Kiosk::Server::AccountBinding).to receive(:bind!).and_call_original

      exchange
      expect_refused('invalid_grant') { exchange }
      expect(Kiosk::Server::AccountBinding).to have_received(:bind!).once
    end
  end
end
