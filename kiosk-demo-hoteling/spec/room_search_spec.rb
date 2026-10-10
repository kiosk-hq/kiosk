# frozen_string_literal: true

require "spec_helper"

RSpec.describe RoomSearch do
  include ActiveSupport::Testing::TimeHelpers

  let(:property) { Property.create!(name: "Search Spec", city: "Istanbul", timezone: "Europe/Istanbul", stars: 4, amenities: []) }

  def errors(**dates) = described_class.new(property:, **dates).tap(&:validate).errors.full_messages

  it "takes both dates or neither" do
    travel_to(Time.find_zone!("Europe/Istanbul").local(2026, 9, 1, 12)) do
      expect(errors).to be_empty
      expect(errors(check_in: "2026-09-01", check_out: "2026-09-02")).to be_empty
      expect(errors(check_in: "2026-09-01").sole).to start_with("check_in and check_out go together")
      expect(errors(check_in: "2026-09-03", check_out: "2026-09-02")).to eq(["check_out must be after check_in"])
    end
  end
end
