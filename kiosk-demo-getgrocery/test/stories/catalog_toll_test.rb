# frozen_string_literal: true

require "test_helper"
require "kiosk/pow/equihash/solver"

class CatalogTollStory < StoryTest
  def reads_the_catalog(shopper, proofs: nil)
    headers = Kiosk::TestHelpers::Wire.bearer(shopper.principal.token)
    headers["Kiosk-PoW"] = JSON.generate(proofs) if proofs
    Kiosk::TestHelpers::Answer.new(Kiosk::TestHelpers::Wire.new(base_url: live_url).get("/kiosk/catalog", {}, headers))
  end

  def solves(challenge) = { challenge:, nonce: Kiosk::Pow::Equihash.solve(challenge) }

  def guesses(challenge, like:) = { challenge:, nonce: { "indices" => (1..like[:nonce]["indices"].size).to_a, "header_nonce" => 0 } }

  test "every catalog read costs the assistant one solved proof of work" do
    shopper = a_shopper

    asked = reads_the_catalog(shopper)
    assert asked.refused?(:pow_required), asked
    challenge = asked["challenges"].sole
    assert_equal({ "n" => 96, "k" => 5 }, challenge["params"].slice("n", "k"))
    proof = solves(challenge)

    guessed = guesses(reads_the_catalog(shopper)["challenges"].sole, like: proof)
    assert_not reads_the_catalog(shopper, proofs: [guessed]).ok?

    paid = reads_the_catalog(shopper, proofs: [proof])
    assert paid.ok?, paid
    assert_not_empty paid.rows
  end
end
