# frozen_string_literal: true

require "test_helper"

class TollStory < StoryTest
  setup { toll(SHIPPED_TOLL) }

  # A search for a table for two, carrying whatever proofs of work the assistant offers.
  def looks_for_a_table(diner, proofs: nil) = diner.asks(:availability, party_size: 2, unpaid: true, proofs:)

  def the_toll_for(diner)
    asked = looks_for_a_table(diner)
    assert asked.refused?(:pow_required), asked
    asked
  end

  def guesses(challenges)
    challenges.map { { challenge: _1, nonce: { "indices" => (1..2**EQUIHASH_PARAMS[:k]).to_a, "header_nonce" => 0 } } }
  end

  test "a new diner's search costs two proofs of work, and only solved ones pay it" do
    diner = a_diner
    challenges = the_toll_for(diner)["challenges"]
    assert_equal [EQUIHASH_PARAMS.transform_keys(&:to_s)] * 2, challenges.map { _1["params"].slice("n", "k") }

    assert looks_for_a_table(diner, proofs: guesses(challenges)).refused?(:forbidden)
    assert looks_for_a_table(diner, proofs: the_toll_for(diner).solved_toll).ok?
  end

  test "the toll falls as the diner's confirmed bookings accrue" do
    diner = a_diner
    assert_equal 2, the_toll_for(diner)["challenges"].size
    assert diner.books.ok?
    assert_equal 1, the_toll_for(diner)["challenges"].size
    assert diner.books.ok?
    assert looks_for_a_table(diner).ok?
  end

  test "under a backoff policy one solved toll buys the next three searches" do
    toll(Kiosk::Reputation::Policies::Backoff.new(
      count: 3, base: { alg: Kiosk::Pow::Equihash::NAME, params: Kiosk::Pow::Equihash.params(**EQUIHASH_PARAMS), count: 1 },
    ))
    diner = a_diner

    assert looks_for_a_table(diner, proofs: the_toll_for(diner).solved_toll).ok?
    assert Array.new(3) { looks_for_a_table(diner) }.all?(&:ok?)
    assert looks_for_a_table(diner).refused?(:pow_required)
  end
end
