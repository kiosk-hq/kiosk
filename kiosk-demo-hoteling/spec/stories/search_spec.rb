# frozen_string_literal: true

require 'story_helper'

RSpec.shared_context 'a guest searching hotels' do
  let(:guest) { a_guest }

  def total(found) = found.header('x-total-count').to_i
end

RSpec.describe 'Finding a hotel', type: :story do
  include_context 'a guest searching hotels'

  it 'a guest pages through every hotel in town, and a narrow search fits on one page' do
    first = guest.searches(limit: 20)
    expect(first).to be_ok
    expect(first.rows).to be_an(Array).and have_attributes(size: 20)
    expect(total(first)).to be > 20

    second = guest.turns_to(first.next_page)
    expect(second.rows).to be_present
    expect(second.rows.pluck('property_id') & first.rows.pluck('property_id')).to be_empty

    narrow = guest.searches(neighbourhood: 'Beşiktaş', min_stars: 4, max_price_cents: 30_000)
    expect(narrow.rows).to be_an(Array)
    expect(narrow.next_page).to be_nil
    expect(total(narrow)).to eq(narrow.rows.size)
  end

  describe 'one hotel, or none' do
    it "a guest reads one hotel's rooms, and is told when a hotel does not exist" do
      hotel = guest.searches(limit: 1).rows.first['property_id']
      detail = guest.looks_at(hotel)
      expect(detail).to be_ok
      expect(detail.rows).to contain_exactly(include('property_id' => hotel, 'room_types' => be_present))

      expect(guest.looks_at(999_999_999)).to be_refused(:not_found)
      expect(guest.rooms_free(at: 999_999_999, check_in: Date.current + 30, check_out: Date.current + 33))
        .to be_refused(:not_found)
    end

    it 'a search that matches nothing comes back empty, and a neighbourhood the city does not have is answered with the ones it does' do
      nothing = guest.searches(neighbourhood: 'Sultanahmet', max_price_cents: 1)
      expect(nothing).to be_ok
      expect([nothing.rows, total(nothing)]).to eq([[], 0])
      expect(guest.searches(neighbourhood: 'Sultanahmet').rows).to be_present

      atlantis = guest.searches(neighbourhood: 'Atlantis')
      expect(atlantis).to be_refused(:bad_request)
      expect(atlantis['detail']).to include('Sultanahmet', 'Beyoğlu', 'Kadıköy')
      expect(atlantis['detail']).not_to include('Atlantis')
    end
  end

  describe 'page size' do
    it 'a guest gets twenty hotels a page, up to fifty on asking, and is told the range when asking for more or for none' do
      expect(guest.searches.rows.size).to eq(20)
      expect(guest.searches(limit: 50).rows.size).to eq(50)

      too_many = guest.searches(limit: 51)
      expect(too_many).to be_refused(:bad_request)
      expect(too_many['detail']).to include('limit', '50')
      expect(guest.searches(limit: 0)).to be_refused(:bad_request)
    end
  end

  describe 'a cursor the guest makes up' do
    it 'a made-up cursor moves through the hotels the search matches, and reaches no other hotel' do
      matching = guest.searches(min_stars: 5, limit: 50)
      expect(matching.rows.size).to be > 1
      expect(matching.next_page).to be_nil

      forged = guest.searches(min_stars: 5, limit: 50, cursor: '1')
      expect(forged).to be_ok
      expect(forged.rows).to eq(matching.rows.drop(1))
      expect(total(forged)).to eq(total(matching))
      expect(guest.searches(min_stars: 5, limit: 50, cursor: '100000').rows).to be_empty
    end
  end
end
