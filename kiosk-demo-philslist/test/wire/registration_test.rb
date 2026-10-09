# frozen_string_literal: true

require "test_helper"

class RegistrationTest < WireTest
  test "registering costs an Equihash proof, and the new assistant posts at once" do
    unproven = assistant.register_raw(pow: :skip)
    assert_equal [402, "pow_required"], [unproven.status, unproven.body["code"]]
    assert_not_empty unproven.body["challenges"]

    post_listing(register)
  end

  test "an unknown category is refused with the categories that exist" do
    refused = assistant.run(register, name: "post_listing", category_slug: "not-a-real-slug", title: "x", body: "y")
    assert_equal [400, "bad_request"], [refused.status, refused.body["code"]]
    Category.pluck(:slug).each { assert_includes refused.body["detail"], _1 }
  end
end
