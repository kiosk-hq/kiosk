# frozen_string_literal: true

require "test_helper"
require "kiosk/pow/equihash/solver"

class CatalogTollTest < WireTest
  def browse(shopper, proofs = nil)
    headers = Kiosk::Redteam::Wire.bearer(shopper.token)
    headers["Kiosk-PoW"] = JSON.generate(proofs) if proofs
    Kiosk::Redteam::Wire.new(base_url: live_url).get_json("/kiosk/catalog", {}, headers)
  end

  def solved(challenge) = { challenge:, nonce: Kiosk::Pow::Equihash.solve(challenge) }

  test "every catalog read costs one Equihash proof, and only a valid one is accepted" do
    shopper = register
    status, toll = browse(shopper)
    assert_equal 402, status, "an unpaid catalog read"
    assert_equal "pow_required", toll["code"]
    challenge = toll["challenges"].sole
    assert_equal({ "n" => 96, "k" => 5 }, challenge["params"].slice("n", "k"))

    proof = solved(challenge)
    _, fresh = browse(shopper)
    forged = { challenge: fresh["challenges"].sole,
               nonce: { "indices" => (1..proof[:nonce]["indices"].size).to_a, "header_nonce" => 0 } }
    assert_equal 403, browse(shopper, [forged]).first

    status, rows = browse(shopper, [proof])
    assert_equal 200, status
    assert_not_empty rows
  end
end
