# frozen_string_literal: true

RSpec.describe Kiosk::Server::DeviceVerification do
  let(:store) { Kiosk::Server::DeviceAuthorizationStores::InMemory.new }
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }

  before do
    Kiosk.configure { |c| c.device_authorization_store = store }
  end

  # Create a pending claim row; returns [plain_user_code, da].
  def fresh
    _plain, plain_user_code, da = Kiosk::Server::DeviceAuthorization.generate(
      client_id: "kiosk-cli", public_key_pem: "PEM",
    )
    store.create(da)
    [plain_user_code, da]
  end

  def display(plain_user_code)
    Kiosk::Server::DeviceAuthorization.display_user_code(plain_user_code)
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
    it "returns the row for a matching pending user_code (hashed lookup)" do
      code, da = fresh
      expect(described_class.find_pending(user_code: code)).to eq(da)
    end

    it "honours the display form (XXXX-XXXX)" do
      code, da = fresh
      expect(described_class.find_pending(user_code: display(code))).to eq(da)
    end

    it "honours case-insensitive lookup (user typed lowercase)" do
      code, da = fresh
      expect(described_class.find_pending(user_code: display(code).downcase)).to eq(da)
    end

    it "returns nil for a code that does not exist" do
      expect(described_class.find_pending(user_code: "NOPECODE")).to be_nil
    end

    it "returns nil when the row has left pending (approved/denied/consumed)" do
      code, da = fresh
      store.update(da.approve(user_id: user_id))
      expect(described_class.find_pending(user_code: code)).to be_nil
    end

    it "returns nil for blank input (no store hit)" do
      expect(described_class.find_pending(user_code: nil)).to be_nil
      expect(described_class.find_pending(user_code: "")).to be_nil
    end
  end

  describe ".approve" do
    it "transitions a pending row to approved with the user_id set" do
      code, = fresh
      approved = described_class.approve(user_code: code, user_id: user_id)
      expect(approved).to be_approved
      expect(approved.user_id).to eq(user_id)
    end

    it "accepts the display form (XXXX-XXXX) at the boundary" do
      code, = fresh
      approved = described_class.approve(user_code: display(code), user_id: user_id)
      expect(approved).to be_approved
    end

    it "raises CodeNotFoundError when no pending row matches" do
      expect {
        described_class.approve(user_code: "NOPECODE", user_id: user_id)
      }.to raise_error(described_class::CodeNotFoundError, /user_code/)
    end

    it "raises CodeNotFoundError when the row has already been approved" do
      code, = fresh
      described_class.approve(user_code: code, user_id: user_id)
      expect {
        described_class.approve(user_code: code, user_id: user_id)
      }.to raise_error(described_class::CodeNotFoundError)
    end

    it "raises ArgumentError when user_id is blank" do
      code, = fresh
      expect { described_class.approve(user_code: code, user_id: nil) }
        .to raise_error(ArgumentError, /user_id/)
      expect { described_class.approve(user_code: code, user_id: "") }
        .to raise_error(ArgumentError, /user_id/)
    end

    # ── the approval IS the role source (ADR-0011 amendment; K-1109) ───────
    it "stamps the approving human's role onto the row, and PERSISTS it" do
      code, da = fresh
      expect(da.requested_role).to be_nil

      approved = described_class.approve(user_code: code, user_id: user_id, role: "owner")
      expect(approved.requested_role).to eq("owner")

      # Read back through the store: the value the token poll will consult is
      # the persisted one, not the object this call happened to return.
      reloaded = store.find_by_device_code_hash(da.device_code_hash)
      expect(reloaded.requested_role).to eq("owner")
    end

    it "leaves the row role-less when the provider's user_idp reports no role" do
      code, da = fresh
      described_class.approve(user_code: code, user_id: user_id, role: nil)
      expect(store.find_by_device_code_hash(da.device_code_hash).requested_role).to be_nil
    end
  end

  describe ".deny" do
    it "transitions a pending row to denied (no user_id needed — the holder said no)" do
      code, = fresh
      denied = described_class.deny(user_code: code)
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
