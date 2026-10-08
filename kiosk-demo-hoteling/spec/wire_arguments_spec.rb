# frozen_string_literal: true

require "spec_helper"

RSpec.describe WireArguments do
  include ActiveSupport::Testing::TimeHelpers

  let(:istanbul) { described_class.default_zone }
  let(:the_15th) { Date.new(2026, 3, 15) }

  def refusal(error = Kiosk::Server::Errors::BadRequest, &block)
    caught = nil
    expect(&block).to raise_error(error) { caught = _1 }
    caught
  end

  it "reads a stay as two days, the checkout after the first night" do
    expect(described_class.stay("2026-09-01", "2026-09-04")).to eq([Date.new(2026, 9, 1), Date.new(2026, 9, 4)])
    expect(refusal { described_class.stay("2026-09-04", "2026-09-01") }.message)
      .to eq("check_out must be after check_in")
    expect(refusal { described_class.stay("2026-09-01", "2026-09-01") }.message)
      .to eq("check_out must be after check_in")
  end

  it "sells today and refuses yesterday on the property's clock, naming the floor and the zone" do
    travel_to istanbul.local(2026, 3, 15, 12) do
      expect(described_class.bookable!(the_15th, zone: istanbul)).to be_nil

      error = refusal { described_class.bookable!(the_15th - 1, zone: istanbul) }
      expect(error.message).to eq("check_in 2026-03-14 is in the past — this hotel sells room-nights " \
                                  "from 2026-03-15 onwards (Europe/Istanbul)")
      expect(error.hint).to include("today IS bookable", "EMPTY availability list")
    end
  end

  it "publishes an example stay that is bookable: three nights from tomorrow" do
    travel_to istanbul.local(2026, 3, 15, 23, 30) do
      expect(described_class.example_check_in).to eq(Date.new(2026, 3, 16))
      expect(described_class.example_check_out).to eq(Date.new(2026, 3, 19))
      expect(described_class.bookable!(described_class.example_check_in, zone: istanbul)).to be_nil
    end
  end

  it "refuses a stay whose total does not fit bookings.total_cents" do
    expect(described_class.priceable_total!(WireArguments::MAX_INT4, 3)).to be_nil

    error = refusal { described_class.priceable_total!(WireArguments::MAX_INT4 + 1, 4) }
    expect(error.message).to include("4-night stay", "max #{WireArguments::MAX_INT4}")
    expect(error.hint).to include("book a shorter stay")
  end

  it "answers a property nobody has with 404, not 400" do
    error = refusal(Kiosk::Server::Errors::NotFound) { described_class.existing_property!(999_999) }
    expect(error.message).to eq("hotel not found: 999999")
    expect(error.hint).to include("search_hotels")
  end
end
