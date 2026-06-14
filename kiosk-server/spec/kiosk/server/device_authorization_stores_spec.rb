# frozen_string_literal: true

RSpec.describe Kiosk::Server::DeviceAuthorizationStores do
  describe Kiosk::Server::DeviceAuthorizationStores::Base do
    subject(:base) { described_class.new }

    it "declares the four abstract operations" do
      expect { base.create(:x) }
        .to raise_error(NotImplementedError)
      expect { base.update(:x) }
        .to raise_error(NotImplementedError)
      expect { base.find_by_device_code_hash("h") }
        .to raise_error(NotImplementedError)
      expect { base.find_by_user_code("c") }
        .to raise_error(NotImplementedError)
    end
  end

  describe Kiosk::Server::DeviceAuthorizationStores::InMemory do
    subject(:store) { described_class.new }
    let(:user_id) { "11111111-1111-1111-1111-111111111111" }
    let(:da) {
      _plain, da = Kiosk::Server::DeviceAuthorization.generate(
        client_id: "kiosk-cli", requested_role: "customer",
      )
      da
    }

    describe "#create" do
      it "stores the row and returns it" do
        result = store.create(da)
        expect(result).to eq(da)
        expect(store.size).to eq(1)
      end

      it "raises UniqueConstraintError on duplicate device_code_hash" do
        store.create(da)
        # Forge a different id but same device_code_hash.
        duplicate = da.with(id: SecureRandom.uuid)
        expect { store.create(duplicate) }
          .to raise_error(Kiosk::Server::DeviceAuthorizationStores::UniqueConstraintError, /device_code_hash/)
      end

      it "raises UniqueConstraintError on duplicate user_code among pending rows" do
        store.create(da)
        # Different device_code_hash, same user_code, both pending.
        other = da.with(id: SecureRandom.uuid, device_code_hash: "different-hash-bytes")
        expect { store.create(other) }
          .to raise_error(Kiosk::Server::DeviceAuthorizationStores::UniqueConstraintError, /user_code/)
      end

      it "permits reuse of a user_code once the prior row left pending" do
        store.create(da)
        # Move the original out of pending.
        store.update(da.approve(user_id: user_id))

        # New pending row with the same user_code is now legal.
        other = da.with(id: SecureRandom.uuid, device_code_hash: "different-hash-bytes")
        expect { store.create(other) }.not_to raise_error
      end
    end

    describe "#update" do
      it "replaces the stored row when id matches" do
        store.create(da)
        approved = da.approve(user_id: user_id)
        store.update(approved)

        expect(store.find_by_device_code_hash(da.device_code_hash)).to be_approved
      end

      it "raises NotFoundError when id has no row" do
        expect { store.update(da) }
          .to raise_error(Kiosk::Server::DeviceAuthorizationStores::NotFoundError, /not found/)
      end
    end

    describe "#find_by_device_code_hash" do
      it "returns the row regardless of status (controllers check expiry/state themselves)" do
        store.create(da)
        store.update(da.approve(user_id: user_id))

        found = store.find_by_device_code_hash(da.device_code_hash)
        expect(found).to be_approved
      end

      it "returns nil when no row matches" do
        expect(store.find_by_device_code_hash("nope")).to be_nil
      end
    end

    describe "#find_by_user_code" do
      it "returns the pending row" do
        store.create(da)
        expect(store.find_by_user_code(da.user_code)).to eq(da)
      end

      it "returns nil once the row leaves pending (approved/consumed/denied invisible)" do
        store.create(da)
        store.update(da.approve(user_id: user_id))
        expect(store.find_by_user_code(da.user_code)).to be_nil
      end

      it "returns nil when no row matches" do
        expect(store.find_by_user_code("NOPECODE")).to be_nil
      end
    end

    describe "#reset! (test helper)" do
      it "clears all stored rows" do
        store.create(da)
        store.reset!
        expect(store.size).to eq(0)
      end
    end
  end

  describe "Kiosk.configuration.device_authorization_store" do
    it "lazy-defaults to an InMemory store" do
      expect(Kiosk.configuration.device_authorization_store)
        .to be_a(Kiosk::Server::DeviceAuthorizationStores::InMemory)
    end

    it "memoises the default across accesses" do
      first  = Kiosk.configuration.device_authorization_store
      second = Kiosk.configuration.device_authorization_store
      expect(second).to equal(first)
    end

    it "accepts an explicit store via the setter" do
      custom = Kiosk::Server::DeviceAuthorizationStores::InMemory.new
      Kiosk.configure { |c| c.device_authorization_store = custom }
      expect(Kiosk.configuration.device_authorization_store).to equal(custom)
    end

    it "Kiosk.reset! drops any configured store" do
      custom = Kiosk::Server::DeviceAuthorizationStores::InMemory.new
      Kiosk.configure { |c| c.device_authorization_store = custom }
      Kiosk.reset!
      expect(Kiosk.configuration.device_authorization_store).not_to equal(custom)
    end
  end
end
