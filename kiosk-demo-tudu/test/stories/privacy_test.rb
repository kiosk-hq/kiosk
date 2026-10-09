# frozen_string_literal: true

require "test_helper"

class PrivacyStory < StoryTest
  setup do
    @owner, @housemate, @stranger = a_member, a_member, a_member
    @list = @owner.starts_a_list("Private")
    @used_code = @owner.invites_to(@list)
    @housemate.joins(@used_code)
  end

  test "a housemate reads the list, and a stranger can neither read it, nor join it, nor see it exists" do
    assert_includes @housemate.list_ids, @list
    assert @housemate.todos_on(@list).ok?

    assert_empty @stranger.lists
    assert @stranger.todos_on(@list).refused?(:forbidden)
    assert @stranger.members_of(@list).refused?(:forbidden)
    assert @stranger.joins(@used_code).refused?(:forbidden)
    assert @stranger.joins("not-a-real-code").refused?(:forbidden)
  end

  test "a housemate the owner removes loses the list at once" do
    assert @owner.removes(@housemate, from: @list).ok?
    assert @housemate.todos_on(@list).refused?(:forbidden)
  end

  test "a list belongs to whoever started it, whoever the arguments name" do
    forged = @stranger.does(:create_list, title: "Forged", account_id: @owner.account)
    assert forged.refused?(:bad_request), forged
    assert_includes forged["detail"], "account_id"

    assert_equal @stranger.account, List.find(@stranger.starts_a_list).account_id
  end

  test "only queries the catalog says reach past the assistant's own account ever show a shared list" do
    queries = published("/kiosk/schema")["queries"]
    assert_equal({ "my_lists" => "consented", "list_todos" => "consented", "list_members" => "consented", "whoami" => "principal" },
                 queries.to_h { [_1["name"], _1["reach"]] }.slice("my_lists", "list_todos", "list_members", "whoami"))

    own_account_only = queries.select { _1["reach"] == "principal" && _1.dig("input_schema", "required").blank? }.pluck("name")
    assert_includes own_account_only, "whoami"
    own_account_only.each do |query|
      answer = @housemate.asks(query)
      assert answer.ok?, query
      assert_not_includes answer.rows.to_json, @list, query
    end
  end
end
