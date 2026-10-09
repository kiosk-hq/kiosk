# frozen_string_literal: true

require "test_helper"

class CatalogTollStory < StoryTest
  def guesses(challenge, like:) = { challenge:, nonce: { "indices" => (1..like[:nonce]["indices"].size).to_a, "header_nonce" => 0 } }

  test "every catalog read costs the assistant one solved proof of work" do
    shopper = a_shopper

    asked = shopper.browses(unpaid: true)
    assert asked.refused?(:pow_required), asked
    challenge = asked["challenges"].sole
    assert_equal({ "n" => 96, "k" => 5 }, challenge["params"].slice("n", "k"))
    toll = asked.solved_toll

    guessed = guesses(shopper.browses(unpaid: true)["challenges"].sole, like: toll.sole)
    assert_not shopper.browses(proofs: [guessed]).ok?

    paid = shopper.browses(proofs: toll)
    assert paid.ok?, paid
    assert_not_empty paid.rows
  end
end
