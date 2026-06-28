# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kiosk::Redteam::Profile do
  describe "defaults" do
    subject(:profile) { described_class.new }

    it "defaults pow_difficulty to 0" do
      expect(profile.pow_difficulty).to eq(0)
    end

    it "defaults requires_kyc to false" do
      expect(profile.requires_kyc).to be(false)
    end

    it "defaults row_id_key to 'id'" do
      expect(profile.row_id_key).to eq("id")
    end

    it "defaults optional callables to nil" do
      expect(profile.per_user_query).to be_nil
      expect(profile.create_owned).to be_nil
      expect(profile.forge_action).to be_nil
      expect(profile.forge_args).to be_nil
      expect(profile.gated_action).to be_nil
      expect(profile.gated_args).to be_nil
      expect(profile.pay_for).to be_nil
      expect(profile.kyc_valid).to be_nil
      expect(profile.kyc_expired).to be_nil
      expect(profile.kyc_forged).to be_nil
    end
  end

  describe "constructor" do
    it "accepts all keyword arguments" do
      create_owned = ->(_c, _p) { { id: "r1" } }
      pay_for      = ->(_c, _p, _r) { { intent: {}, cart: {} } }
      kyc_valid    = ->(_uid) { "valid.jws" }

      profile = described_class.new(
        pow_difficulty: 20,
        requires_kyc:   true,
        per_user_query: "my_reservations",
        row_id_key:     "reservation_id",
        create_owned:   create_owned,
        forge_action:   "reserve",
        forge_args:     ->(_c, _a, _b) { { scooter_code: "SK-001" } },
        gated_action:   "start_rental",
        gated_args:     ->(ref) { { reservation_id: ref[:id] } },
        pay_for:        pay_for,
        kyc_valid:      kyc_valid,
        kyc_expired:    ->(_uid) { "expired.jws" },
        kyc_forged:     ->(_uid) { "forged.jws" },
      )

      expect(profile.pow_difficulty).to eq(20)
      expect(profile.requires_kyc).to be(true)
      expect(profile.per_user_query).to eq("my_reservations")
      expect(profile.row_id_key).to eq("reservation_id")
      expect(profile.create_owned).to be(create_owned)
      expect(profile.forge_action).to eq("reserve")
      expect(profile.gated_action).to eq("start_rental")
      expect(profile.pay_for).to be(pay_for)
      expect(profile.kyc_valid).to be(kyc_valid)
    end

    it "raises ArgumentError on unknown keyword" do
      expect {
        described_class.new(unknown_field: "oops")
      }.to raise_error(ArgumentError)
    end
  end
end
