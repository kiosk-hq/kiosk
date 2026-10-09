# frozen_string_literal: true

require "test_helper"

class IsolationTest < WireTest
  setup do
    @alice = register
    @bob   = register
    @alices = post_listing(@alice, price_text: "€80")
    @bobs   = post_listing(@bob)
  end

  def ids(answer) = answer.body.map { _1["listing_id"] }

  test "the board shows every seller's listings, and my_listings only the caller's" do
    assert_empty [@alices, @bobs] - ids(assistant.query(@bob, name: "browse_listings"))
    assert_equal [@bobs], ids(assistant.query(@bob, name: "my_listings"))
  end

  test "one seller can neither edit nor close another's listing" do
    edit  = assistant.run(@bob, name: "edit_listing", listing_id: @alices, price_text: "€1")
    close = assistant.run(@bob, name: "close_listing", listing_id: @alices)

    assert_equal [403, "forbidden"], [edit.status, edit.body["code"]]
    assert_equal [403, "forbidden"], [close.status, close.body["code"]]
    assert_equal %w[open €80], Listing.find(@alices).values_at(:status, :price_text)

    assert_equal 200, assistant.run(@alice, name: "edit_listing", listing_id: @alices, price_text: "€1").status
    assert_equal 200, assistant.run(@alice, name: "close_listing", listing_id: @alices).status
  end

  test "the owner and the posting assistant come from the token, never from an argument" do
    forged = assistant.run(@bob, name: "post_listing", category_slug: "furniture", title: "Desk", body: "Oak",
                              owner_id: @alice.user_id)
    assert_equal [400, "bad_request"], [forged.status, forged.body["code"]]
    assert_includes forged.body["detail"], "owner_id"

    listing = Listing.find(post_listing(@bob))
    assert_equal [@bob.user_id, @bob.agent_id], [listing.owner_id, listing.created_by_agent_id]
  end

  test "only the board declares a reach beyond the caller, and every other query keeps to it" do
    queries = published("/kiosk/schema")["queries"]
    assert_equal({ "browse_listings" => "published", "my_listings" => "principal" },
                 queries.to_h { [_1["name"], _1["reach"]] })

    principal_scoped = queries.select { _1["reach"] == "principal" && _1.dig("input_schema", "required").blank? }
    assert_not_empty principal_scoped
    principal_scoped.each do |query|
      answer = assistant.query(@bob, name: query["name"])
      assert_equal 200, answer.status
      assert_not_includes ids(answer), @alices, query["name"]
    end
  end
end
