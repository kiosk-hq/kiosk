# frozen_string_literal: true

require "wire_helper"

RSpec.describe "searching the hotels", :wire do
  let(:guest) { register }

  def search(**params) = tolled_get(guest, "/kiosk/search_hotels", **params).first
  def query(name, **params) = tolled_get(guest, "/kiosk/#{name}", **params).first
  def next_page(answer) = answer["link"].to_s[/<([^>]*)>\s*;\s*rel="next"/, 1]
  def total(answer) = answer["x-total-count"]&.to_i

  it "pages a long result with a Link to the next page, and a complete one without" do
    first = search(limit: 20)
    expect(first.status).to eq(200)
    expect(first.body).to be_an(Array).and have_attributes(size: 20)
    expect(total(first)).to be > 20

    second = tolled_get(guest, URI(next_page(first)).request_uri).first
    expect(second.body).to be_present
    expect(second.body.pluck("property_id") & first.body.pluck("property_id")).to be_empty

    filtered = search(neighbourhood: "Beşiktaş", min_stars: 4, max_price_cents: 30_000)
    expect(filtered.body).to be_an(Array)
    expect(next_page(filtered)).to be_nil
    expect(total(filtered)).to eq(filtered.body.size)
  end

  it "answers one hotel's detail as a one-row array, and 404 for an id nobody has" do
    id = search(limit: 1).body.first["property_id"]
    detail = query("hotel_detail", property_id: id)
    expect(detail.status).to eq(200)
    expect(detail.body).to contain_exactly(include("property_id" => id, "room_types" => be_present))

    unknown = query("hotel_detail", property_id: 999_999_999)
    expect([unknown.status, unknown.body["code"]]).to eq([404, "not_found"])
    unknown = query("availability", property_id: 999_999_999,
                                    check_in: (Date.current + 30).iso8601, check_out: (Date.current + 33).iso8601)
    expect([unknown.status, unknown.body["code"]]).to eq([404, "not_found"])
  end

  it "answers a filter that matched nothing with an empty page, and an unknown value with the valid ones" do
    empty = search(neighbourhood: "Sultanahmet", max_price_cents: 1)
    expect([empty.status, empty.body, total(empty)]).to eq([200, [], 0])
    expect(search(neighbourhood: "Sultanahmet").body).to be_present

    unknown = search(neighbourhood: "Atlantis")
    expect([unknown.status, unknown.body["code"]]).to eq([400, "bad_request"])
    expect(unknown.body["detail"]).to include("Sultanahmet", "Beyoğlu", "Kadıköy")
    expect(unknown.body["detail"]).not_to include("Atlantis")
  end

  it "clamps the page size to 1..50 rather than refusing it" do
    floor = search(limit: 0)
    expect([floor.status, floor.body.size]).to eq([200, 1])
    expect(total(floor)).to be > 1
    expect(search(limit: -5).body.size).to eq(1)
    expect(search(limit: 500).body.size).to eq(50)
  end
end
