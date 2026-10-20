# frozen_string_literal: true

require 'spec_helper'

RSpec.shared_context 'two guests with a booking each' do
  let(:ada) { User.create!(email: 'ada-conformance@example.test', password: 'conformance-fixture') }
  let(:ben) { User.create!(email: 'ben-conformance@example.test', password: 'conformance-fixture') }

  let(:property) do
    Property.create!(name: 'Gran Hotel Conformance', city: 'Istanbul',
                     neighbourhood: 'Beşiktaş', stars: 5, amenities: [],
                     address: '1 Barbaros Blv, Beşiktaş, Istanbul')
  end

  let(:check_in)  { Date.current + 30 }
  let(:check_out) { Date.current + 32 }

  def book_for(user, room_type)
    Booking.create!(user_id: user.id, property_id: property.id, room_type_id: room_type.id,
                    check_in: check_in, check_out: check_out,
                    total_cents: room_type.nightly_price_cents * 2, status: :reserved)
  end

  before do
    book_for(ada, RoomType.create!(property: property, name: 'Double', nightly_price_cents: 18_000))
    book_for(ben, RoomType.create!(property: property, name: 'Suite', nightly_price_cents: 32_000))
  end
end

RSpec.describe 'Kiosk conformance' do
  include_context 'two guests with a booking each'

  it 'routes every verb it declares, with the method its kind requires' do
    expect(kiosk_origin).to have_a_route_for_every_verb
  end

  it 'executes its read surface as a signed-in customer' do
    expect(:properties).to    execute_as_a_kiosk_verb(as: ada)
    expect(:my_bookings).to   execute_as_a_kiosk_verb(as: ada)
    expect(:search_hotels).to execute_as_a_kiosk_verb(as: ada)
  end

  describe 'declared schemas' do
    it 'answers the shape `properties` publishes' do
      expect(:properties).to answer_its_declared_schema(as: ada)
    end

    it 'answers the shape `my_bookings` publishes' do
      expect(:my_bookings).to answer_its_declared_schema(as: ada)
    end

    it 'answers the shape `search_hotels` publishes, running its own example' do
      expect(:search_hotels).to answer_its_declared_schema(as: ada)
    end

    it 'answers the shape `availability` publishes' do
      expect(:availability).to answer_its_declared_schema(
        as: ada,
        params: { property_id: property.id,
                  check_in: check_in.iso8601,
                  check_out: check_out.iso8601 }
      )
    end
  end

  describe 'principal scoping' do
    it 'hands one guest nothing belonging to another' do
      expect(:my_bookings).to be_scoped_to_principal(as: ada, and_not: ben)
    end

    it 'publishes the same shelf to every customer' do
      ada_shelf = Kiosk::TestHelpers::Conformance.executes(:properties, as: ada)
      ben_shelf = Kiosk::TestHelpers::Conformance.executes(:properties, as: ben)

      expect(ada_shelf).to be_ok
      expect(ben_shelf).to be_ok
      expect(ada_shelf.details[:answer]).to eq(ben_shelf.details[:answer])
    end
  end
end
