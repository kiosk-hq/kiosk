# frozen_string_literal: true

require "test_helper"

class RegistrationTest < WireTest
  test "registering costs a solved proof of work, and the token it buys reads the catalogue" do
    unpaid = client.register_raw(name: "visitor", pow: :skip)
    assert_equal [402, "pow_required"], [unpaid.status, unpaid.body["code"]]
    assert_equal 1, unpaid.body["challenges"].size

    paid = client.register_raw(name: "visitor")
    assert_equal [201, true], [paid.status, paid.pow_retried]

    assistant = Kiosk::Redteam::Principal.new(agent_id: paid.body["agent_id"], user_id: paid.body["user_id"],
                                              token: paid.body["access_token"], rsa_key: nil)
    salons = client.query(assistant, name: "salons")
    assert_equal [200, ["Combette on Park"]], [salons.status, salons.body.map { _1["name"] }]
  end
end
