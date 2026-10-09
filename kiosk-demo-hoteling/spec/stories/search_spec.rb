# frozen_string_literal: true

require "story_helper"

RSpec.describe "Finding a hotel", type: :story do
  let(:guest) { a_guest }

  def total(found) = found.header("x-total-count").to_i

  it "a guest pages through every hotel in town, and a narrow search fits on one page" do
    first = guest.searches(limit: 20)
    expect(first).to be_ok
    expect(first.rows).to be_an(Array).and have_attributes(size: 20)
    expect(total(first)).to be > 20

    second = guest.turns_to(first.next_page)
    expect(second.rows).to be_present
    expect(second.rows.pluck("property_id") & first.rows.pluck("property_id")).to be_empty

    narrow = guest.searches(neighbourhood: "Beşiktaş", min_stars: 4, max_price_cents: 30_000)
    expect(narrow.rows).to be_an(Array)
    expect(narrow.next_page).to be_nil
    expect(total(narrow)).to eq(narrow.rows.size)
  end

  it "a guest reads one hotel's rooms, and is told when a hotel does not exist" do
    hotel = guest.searches(limit: 1).rows.first["property_id"]
    detail = guest.looks_at(hotel)
    expect(detail).to be_ok
    expect(detail.rows).to contain_exactly(include("property_id" => hotel, "room_types" => be_present))

    expect(guest.looks_at(999_999_999)).to be_refused(:not_found)
    expect(guest.rooms_free(at: 999_999_999, check_in: Date.current + 30, check_out: Date.current + 33))
      .to be_refused(:not_found)
  end

  it "a search that matches nothing comes back empty, and a neighbourhood the city does not have is answered with the ones it does" do
    nothing = guest.searches(neighbourhood: "Sultanahmet", max_price_cents: 1)
    expect(nothing).to be_ok
    expect([nothing.rows, total(nothing)]).to eq([[], 0])
    expect(guest.searches(neighbourhood: "Sultanahmet").rows).to be_present

    atlantis = guest.searches(neighbourhood: "Atlantis")
    expect(atlantis).to be_refused(:bad_request)
    expect(atlantis["detail"]).to include("Sultanahmet", "Beyoğlu", "Kadıköy")
    expect(atlantis["detail"]).not_to include("Atlantis")
  end

  it "a guest asking for fewer than one or more than fifty hotels at once gets one or fifty" do
    one = guest.searches(limit: 0)
    expect(one).to be_ok
    expect(one.rows.size).to eq(1)
    expect(total(one)).to be > 1
    expect(guest.searches(limit: -5).rows.size).to eq(1)
    expect(guest.searches(limit: 500).rows.size).to eq(50)
  end
end
