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
    as(@alice) do
      assert_equal @listing, EditListingOperation.call(listing_id: @listing.id, changes: { 'price_text' => nil })
    end
    assert_nil @listing.reload.price_text
  end

  test 'the owner closes their listing' do
    as(@alice) do
      assert_equal @listing, CloseListingOperation.call(listing_id: @listing.id)
    end
    assert_predicate @listing.reload, :closed?
  end

  test 'a foreign listing and an absent one are refused alike' do
    [@listing.id, SecureRandom.uuid].each do |id|
      edit, close = bobs_refusals(id)

      assert_equal 'listing_id is not one of your listings.', edit.message
      assert_equal [edit.message, edit.hint], [close.message, close.hint]
    end
  end

  test 'a refused edit and close leave the listing as it was' do
    bobs_refusals(@listing.id)

    assert_predicate @listing.reload, :open?
    assert_equal 'Road bike', @listing.title
  end

  test 'an edit cannot blank the title' do
    as(@alice) do
      assert_raises(ActiveRecord::RecordInvalid) do
        EditListingOperation.call(listing_id: @listing.id, changes: { 'title' => '' })
      end
    end
    assert_equal 'Road bike', @listing.reload.title
  end

  private

  # Bob edits and closes a listing that is not his; answers both refusals.
  def bobs_refusals(listing_id)
    as(@bob) do
      [assert_raises(Kiosk::Server::Errors::Forbidden) { EditListingOperation.call(listing_id:, changes: { 'title' => 'x' }) },
       assert_raises(Kiosk::Server::Errors::Forbidden) { CloseListingOperation.call(listing_id:) }]
    end
  end
end
