# frozen_string_literal: true

RSpec.describe Kiosk::Server::DeviceVerification do
  let(:store) { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }

  before do
    Kiosk.configure { |c| c.device_authorization_store = store }
  end

  def fresh
    _plain, da = Kiosk::Server::DeviceAuthorization.generate(client_id: "kiosk-cli")
    store.create(da)
    da
  end

  describe ".normalize_user_code" do
    it "strips the XXXX-XXXX visual dash" do
      expect(described_class.normalize_user_code("WDJB-MJHT")).to eq("WDJBMJHT")
    end

    it "strips ambient whitespace from copy/paste" do
      expect(described_class.normalize_user_code("  WDJB MJHT  ")).to eq("WDJBMJHT")
      expect(described_class.normalize_user_code("\tWDJB\nMJHT\r\n")).to eq("WDJBMJHT")
    end

    it "upcases lowercase input (auto-cap keyboards / browsers)" do
      expect(described_class.normalize_user_code("wdjb-mjht")).to eq("WDJBMJHT")
    end

    it "returns empty string for blank input" do
      expect(described_class.normalize_user_code(nil)).to eq("")
      expect(described_class.normalize_user_code("")).to eq("")
      expect(described_class.normalize_user_code("   ")).to eq("")
    end
  end

  describe ".find_pending" do
    it "returns the row for a matching pending user_code" do
      da = fresh
      expect(described_class.find_pending(user_code: da.user_code)).to eq(da)
    end

    it "honours the display form (XXXX-XXXX)" do
      da = fresh
      expect(described_class.find_pending(user_code: da.display_user_code)).to eq(da)
    end

    it "honours case-insensitive lookup (user typed lowercase)" do
      da = fresh
      expect(described_class.find_pending(user_code: da.display_user_code.downcase)).to eq(da)
    end

    it "returns nil for a code that does not exist" do
      expect(described_class.find_pending(user_code: "NOPECODE")).to be_nil
    end

    it "returns nil when the row has left pending (approved/denied/consumed)" do
      da = fresh
      store.update(da.approve(user_id: user_id))
      expect(described_class.find_pending(user_code: da.user_code)).to be_nil
    end

    it "returns nil for blank input (no DB hit)" do
      expect(described_class.find_pending(user_code: nil)).to be_nil
      expect(described_class.find_pending(user_code: "")).to be_nil
    end
  end

  describe ".approve" do
    it "transitions a pending row to approved with the user_id set" do
      da = fresh
      approved = described_class.approve(user_code: da.user_code, user_id: user_id)
      expect(approved).to be_approved
      expect(approved.user_id).to eq(user_id)
    end

    it "accepts the display form (XXXX-XXXX) at the boundary" do
      da = fresh
      approved = described_class.approve(user_code: da.display_user_code, user_id: user_id)
      expect(approved).to be_approved
    end

    it "raises CodeNotFoundError when no pending row matches" do
      expect {
        described_class.approve(user_code: "NOPECODE", user_id: user_id)
      }.to raise_error(described_class::CodeNotFoundError, /user_code/)
    end

    it "raises CodeNotFoundError when the row has already been approved" do
      da = fresh
      described_class.approve(user_code: da.user_code, user_id: user_id)
      expect {
        described_class.approve(user_code: da.user_code, user_id: user_id)
      }.to raise_error(described_class::CodeNotFoundError)
    end

    it "raises ArgumentError when user_id is blank" do
      da = fresh
      expect { described_class.approve(user_code: da.user_code, user_id: nil) }
        .to raise_error(ArgumentError, /user_id/)
      expect { described_class.approve(user_code: da.user_code, user_id: "") }
        .to raise_error(ArgumentError, /user_id/)
    end
  end

  describe ".deny" do
    it "transitions a pending row to denied (no user_id needed — user said no)" do
      da = fresh
      denied = described_class.deny(user_code: da.user_code)
      expect(denied).to be_denied
      expect(denied.user_id).to be_nil
    end

    it "raises CodeNotFoundError when no pending row matches" do
      expect {
        described_class.deny(user_code: "NOPECODE")
      }.to raise_error(described_class::CodeNotFoundError)
    end
  end
end
