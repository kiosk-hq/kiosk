# frozen_string_literal: true

require "test_helper"
require "kiosk/pow/equihash/solver"

class TollTest < WireTest
  setup { toll(SHIPPED_TOLL) }

  def availability(diner, proofs = nil)
    headers = wire.bearer(diner.token)
    headers["Kiosk-PoW"] = JSON.generate(proofs) if proofs
    wire.get_json("/kiosk/availability", { party_size: 2 }, headers).first
  end

  def challenges(diner)
    status, body = wire.get_json("/kiosk/availability", { party_size: 2 }, wire.bearer(diner.token))
    assert_equal [402, "pow_required"], [status, body["code"]]
    body["challenges"]
  end

  def solved(challenges) = challenges.map { { challenge: _1, nonce: Kiosk::Pow::Equihash.solve(_1) } }

  test "a new diner's query costs two Equihash proofs, and only solved ones pay it" do
    diner = register
    issued = challenges(diner)
    assert_equal [EQUIHASH_PARAMS.transform_keys(&:to_s)] * 2, issued.map { _1["params"].slice("n", "k") }

    guessed = issued.map { { challenge: _1, nonce: { "indices" => (1..2**EQUIHASH_PARAMS[:k]).to_a, "header_nonce" => 0 } } }
    assert_equal 403, availability(diner, guessed)
    assert_equal 200, availability(diner, solved(challenges(diner)))
  end

  test "the toll falls as the diner's confirmed bookings accrue" do
    diner = register
    assert_equal 2, challenges(diner).size
    assert_equal 200, book(diner).status
    assert_equal 1, challenges(diner).size
    assert_equal 200, book(diner).status
    assert_equal 200, availability(diner)
  end

  test "under a backoff policy one solved toll buys the next three queries" do
    toll(Kiosk::Reputation::Policies::Backoff.new(
      count: 3, base: { alg: Kiosk::Pow::Equihash::NAME, params: Kiosk::Pow::Equihash.params(**EQUIHASH_PARAMS), count: 1 },
    ))
    diner = register

    assert_equal 200, availability(diner, solved(challenges(diner)))
    assert_equal [200, 200, 200, 402], Array.new(4) { availability(diner) }
  end
end
