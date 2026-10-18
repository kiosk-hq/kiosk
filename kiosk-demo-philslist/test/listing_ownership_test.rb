# frozen_string_literal: true

require 'test_helper'

class ListingOwnershipTest < ActiveSupport::TestCase
  setup do
    @alice   = User.create!(email: 'alice@example.test', password: 'test-password')
    @bob     = User.create!(email: 'bob@example.test', password: 'test-password')
    @listing = Listing.create!(owner: @alice, category: Category.create!(slug: 'bikes', name: 'Bikes'),
                               title: 'Road bike', body: '54cm', price_text: '€300')
  end

  test 'the owner edits their listing' do
    as(@alice) { Listing.own!(@listing.id).update!(price_text: nil) }

    assert_nil @listing.reload.price_text
  end

  test 'the owner closes their listing' do
    as(@alice) { Listing.own!(@listing.id).closed! }

    assert_predicate @listing.reload, :closed?
  end

  test 'a foreign listing and an absent one are refused alike' do
    [@listing.id, SecureRandom.uuid].each do |id|
      refusal = as(@bob) { assert_raises(Kiosk::Server::Errors::Forbidden) { Listing.own!(id) } }

      assert_equal ['listing_id is not one of your listings.', 'Pass a listing_id from my_listings.'],
                   [refusal.message, refusal.hint]
    end
  end

  test 'an edit cannot blank the title' do
    as(@alice) do
      assert_raises(ActiveRecord::RecordInvalid) { Listing.own!(@listing.id).update!(title: '') }
    end
    assert_equal 'Road bike', @listing.reload.title
  end
end
