# frozen_string_literal: true

require 'test_helper'

class SellingStory < StoryTest
  test 'a seller who retitles a listing keeps its price, and clears the price only by saying so' do
    seller  = a_seller
    listing = seller.posts(price_text: '€80')

    assert_predicate seller.edits(listing, title: 'Pine bookshelf'), :ok?
    assert_equal '€80', seller.price_of(listing)

    assert_predicate seller.edits(listing, price_text: nil), :ok?
    assert_nil seller.price_of(listing)
  end
end
