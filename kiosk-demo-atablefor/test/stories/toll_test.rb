# frozen_string_literal: true

require "test_helper"
require "kiosk/pow/equihash/solver"

class TollStory < StoryTest
  setup { toll(SHIPPED_TOLL) }

  # A search for a table for two, carrying whatever proofs of work the assistant offers.
  def looks_for_a_table(diner, proofs: nil)
    headers = Kiosk::TestHelpers::Wire.bearer(diner.principal.token)
    headers["Kiosk-PoW"] = JSON.generate(proofs) if proofs
    Kiosk::TestHelpers::Answer.new(Kiosk::TestHelpers::Wire.new(base_url: live_url).get("/kiosk/availability", { party_size: 2 }, headers))
  end

  def the_toll_for(diner)
    asked = looks_for_a_table(diner)
    assert asked.refused?(:pow_required), asked
    asked["challenges"]
  end

  def solves(challenges) = challenges.map { { challenge: _1, nonce: Kiosk::Pow::Equihash.solve(_1) } }

  def guesses(challenges)
    challenges.map { { challenge: _1, nonce: { "indices" => (1..2**EQUIHASH_PARAMS[:k]).to_a, "header_nonce" => 0 } } }
  end

  test "a new diner's search costs two proofs of work, and only solved ones pay it" do
    diner = a_diner
    toll = the_toll_for(diner)
    assert_equal [EQUIHASH_PARAMS.transform_keys(&:to_s)] * 2, toll.map { _1["params"].slice("n", "k") }

    assert looks_for_a_table(diner, proofs: guesses(toll)).refused?(:forbidden)
    assert looks_for_a_table(diner, proofs: solves(the_toll_for(diner))).ok?
  end

  test "the toll falls as the diner's confirmed bookings accrue" do
    diner = a_diner
    assert_equal 2, the_toll_for(diner).size
    assert diner.books.ok?
    assert_equal 1, the_toll_for(diner).size
    assert diner.books.ok?
    assert looks_for_a_table(diner).ok?
  end

  test "under a backoff policy one solved toll buys the next three searches" do
    toll(Kiosk::Reputation::Policies::Backoff.new(
      count: 3, base: { alg: Kiosk::Pow::Equihash::NAME, params: Kiosk::Pow::Equihash.params(**EQUIHASH_PARAMS), count: 1 },
    ))
    diner = a_diner

    assert looks_for_a_table(diner, proofs: solves(the_toll_for(diner))).ok?
    assert Array.new(3) { looks_for_a_table(diner) }.all?(&:ok?)
    assert looks_for_a_table(diner).refused?(:pow_required)
  end
end
