# frozen_string_literal: true

require "test_helper"

class OperationsTest < ActiveSupport::TestCase
  setup { @alice, @bob, @list = household }

  test "a deadline is stored as the instant its offset names" do
    todo_id = as(@bob) do
      AddTodoOperation.call(agent_id: nil, list_id: @list.id, title: "Book campsite",
                            due_at: "2026-09-15T01:00:00+13:00")[:todo_id]
    end
    assert_equal Time.utc(2026, 9, 14, 12), Todo.find(todo_id).due_at
  end

  test "a todo needs a title, and a list its principal is on" do
    as(@bob) do
      assert_raises(Kiosk::Server::Errors::BadRequest) do
        AddTodoOperation.call(agent_id: nil, list_id: @list.id, title: "  ")
      end
    end
    as(User.create!) do
      assert_raises(Kiosk::Server::Errors::Forbidden) do
        AddTodoOperation.call(agent_id: nil, list_id: @list.id, title: "Sneak in")
      end
    end
  end

  test "only a member completes a todo" do
    todo = @list.todos.create!(title: "Buy dish soap")
    as(User.create!) do
      assert_raises(Kiosk::Server::Errors::Forbidden) { CompleteTodoOperation.call(todo_id: todo.id) }
    end
    as(@bob) { CompleteTodoOperation.call(todo_id: todo.id) }
    assert todo.reload.done
  end

  test "an invite is redeemed once, and never after it expires" do
    carol = User.create!
    dave  = User.create!
    code  = as(@alice) { InviteOperation.call(principal_id: @alice.id, list_id: @list.id)[:code] }

    assert_equal({ list_id: @list.id, joined: true }, as(carol) { AcceptInviteOperation.call(principal_id: carol.id, code: code) })
    assert @list.memberships.member.exists?(account: carol)
    assert_raises(Kiosk::Server::Errors::Forbidden) { as(dave) { AcceptInviteOperation.call(principal_id: dave.id, code: code) } }

    late = as(@alice) { InviteOperation.call(principal_id: @alice.id, list_id: @list.id)[:code] }
    travel(InviteOperation::TTL + 1.second) do
      assert_raises(Kiosk::Server::Errors::Forbidden) { as(dave) { AcceptInviteOperation.call(principal_id: dave.id, code: late) } }
    end
  end

  test "an owner redeeming her own invite stays the owner" do
    code = as(@alice) { InviteOperation.call(principal_id: @alice.id, list_id: @list.id)[:code] }
    as(@alice) { AcceptInviteOperation.call(principal_id: @alice.id, code: code) }
    assert @list.memberships.owner.exists?(account: @alice)
  end

  test "an owner removes a member, but never the last owner" do
    as(@bob) do
      assert_raises(Kiosk::Server::Errors::Forbidden) { RemoveMemberOperation.call(list_id: @list.id, account_id: @alice.id) }
    end
    as(@alice) do
      error = assert_raises(Kiosk::Server::Errors::Forbidden) do
        RemoveMemberOperation.call(list_id: @list.id, account_id: @alice.id.upcase)
      end
      assert_equal "cannot remove the list's last owner", error.message
      assert_equal({ removed: true }, RemoveMemberOperation.call(list_id: @list.id, account_id: @bob.id))
    end
    assert_not @list.memberships.exists?(account: @bob)
  end
end
