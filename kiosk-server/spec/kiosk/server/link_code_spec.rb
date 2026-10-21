# frozen_string_literal: true

# Account binding started by the human: the link code a signed-in holder
# mints, and its single redemption by a registered client.
RSpec.describe Kiosk::Server::LinkCode do
  include_context 'with registered clients'

  let(:store)  { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:holder) { holder! }
  let(:client) { register_client }
  let(:minted) { described_class.mint(user_id: holder, requested_role: 'owner', store: store) }
  let(:code)   { minted[:link_code] }

  def redeem(code = self.code, client: self.client, key: agent_key, **)
    described_class.redeem(code: code, assertion_type: Kiosk::Server::ClientAssertion::TYPE,
                           assertion: client_assertion(client.id, key: key), store: store, **)
  end

  def row = store.lookup_by_device_code_hash(minted[:da].device_code_hash)

  describe '.mint' do
    it 'creates a pre-approved :link row bound to the holder and returns the plain code' do
      expect(minted).to include(link_code: be_a(String), expires_in: Kiosk::Server::DeviceAuthorization::DEFAULT_EXPIRES_IN)
      expect(minted[:da]).to be_approved.and be_link
      expect([minted[:da].user_id, minted[:da].client_id]).to eq([holder, described_class::CLIENT_ID])
    end

    it 'persists only the hash of the link code' do
      expect(store.lookup_by_device_code_hash(Kiosk::Server::DeviceAuthorization.hash_device_code(code))).to eq(minted[:da])
    end

    # roles-from-IdP: the human's role travels on the link row.
    it "stamps the human's role onto the row, and none for a role-less human" do
      expect(minted[:da].requested_role).to eq('owner')
      expect(described_class.mint(user_id: holder, store: store)[:da].requested_role).to be_nil
    end
  end

  describe '.redeem' do
    it "binds the client to the holder with the holder's role, and consumes the code" do
      bound = redeem

      expect([bound.id, bound.user_id, bound.role]).to eq([client.id, holder, 'owner'])
      expect(row).to be_consumed
      expect { redeem }.to raise_error(Kiosk::Server::Errors::Conflict, /already used/)
    end

    it 'lets only ONE of two clients bind with one code' do
      redeem
      expect { redeem(client: register_client(other_key), key: other_key) }
        .to raise_error(Kiosk::Server::Errors::Conflict)
    end

    it 'refuses a client assertion and leaves the code live' do
      expect { redeem(key: other_key) }.to raise_error(Kiosk::Server::ClientAssertion::Refused, /signature invalid/)
      expect(row).to be_approved
      expect(redeem.user_id).to eq(holder)
    end

    it 'refuses a blank, an unknown and an expired code, and a claim-flow device_code' do
      expect { redeem('') }.to raise_error(Kiosk::Server::Errors::BadRequest, /code required/)
      expect { redeem('no-such-code') }.to raise_error(Kiosk::Server::Errors::NotFound, /unknown link code/)
      claim = Kiosk::Server::DeviceCodeGrant.start(client: client, store: store)
      expect { redeem(claim[:device_code]) }.to raise_error(Kiosk::Server::Errors::NotFound, /unknown link code/)
      expect { redeem(now: minted[:da].expires_at + 1) }.to raise_error(Kiosk::Server::Errors::NotFound, /expired/)
      expect(row).to be_expired
    end
  end
end
