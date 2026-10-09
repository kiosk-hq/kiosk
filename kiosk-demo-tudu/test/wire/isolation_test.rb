# frozen_string_literal: true

require "test_helper"

class IsolationTest < WireTest
  setup do
    @owner   = register
    @member  = register
    @mallory = register
    @list_id = create_list(@owner, "Private")
    @used_code = invite(@owner, @list_id)
    join(@member, @used_code)
  end

  test "a member reads the list, and a stranger can neither read it, nor join it, nor see it" do
    assert_includes list_ids(@member), @list_id
    assert_equal 200, assistant.query(@member, name: "list_todos", list_id: @list_id).status

    assert_empty list_ids(@mallory)
    %w[list_todos list_members].each do |query|
      assert_equal 403, assistant.query(@mallory, name: query, list_id: @list_id).status, query
    end
    [@used_code, "not-a-real-code"].each do |code|
      assert_equal 403, assistant.run(@mallory, name: "accept_invite", code:).status, code
    end
  end

  test "a removed member loses the list at once" do
    assert_equal 200, assistant.run(@owner, name: "remove_member", list_id: @list_id, account_id: @member.user_id).status
    assert_equal 403, assistant.query(@member, name: "list_todos", list_id: @list_id).status
  end

  test "the principal is not an argument" do
    forged = assistant.run(@mallory, name: "create_list", title: "Forged", account_id: @owner.user_id)
    assert_equal [400, "bad_request"], [forged.status, forged.body["code"]]
    assert_includes forged.body["detail"], "account_id"

    assert_equal @mallory.user_id, List.find(create_list(@mallory)).account_id
  end

  test "the catalog declares which queries reach past the principal, and no query claiming the principal returns a shared list" do
    _, catalog = wire.get_json("/kiosk/schema")
    reach = catalog["queries"].to_h { [_1["name"], _1["reach"]] }
    assert_equal({ "my_lists" => "consented", "list_todos" => "consented", "list_members" => "consented", "whoami" => "principal" },
                 reach.slice("my_lists", "list_todos", "list_members", "whoami"))

    principal_only = catalog["queries"].select { _1["reach"] == "principal" && _1.dig("input_schema", "required").blank? }
    assert_includes principal_only.map { _1["name"] }, "whoami"
    principal_only.each do |query|
      answer = assistant.query(@member, name: query["name"])
      assert_equal 200, answer.status, query["name"]
      assert_not_includes answer.body.to_json, @list_id, query["name"]
    end
  end
end
