# frozen_string_literal: true

require 'test_helper'

class OperationsTest < ActiveSupport::TestCase
  setup { @alice, @bob, @list = household }

  test 'a deadline is stored as the instant its offset names' do
    todo_id = as(@bob) do
      AddTodoOperation.call(agent_id: nil, list_id: @list.id, title: 'Book campsite',
                            due_at: '2026-09-15T01:00:00+13:00').id
    end

    assert_equal Time.utc(2026, 9, 14, 12), Todo.find(todo_id).due_at
  end

  test 'a todo needs a title, and a list its member is on' do
    as(@bob) do
      assert_raises(ActiveRecord::RecordInvalid) do
        AddTodoOperation.call(agent_id: nil, list_id: @list.id, title: '  ')
      end
    end
    as(User.create!) do
      assert_raises(Kiosk::Server::Errors::Forbidden) do
        AddTodoOperation.call(agent_id: nil, list_id: @list.id, title: 'Sneak in')
      end
    end
  end

  test 'only a member completes a todo' do
    todo = @list.todos.create!(title: 'Buy dish soap')

    as(User.create!) do
      assert_raises(Kiosk::Server::Errors::Forbidden) { CompleteTodoOperation.call(todo_id: todo.id) }
    end
    as(@bob) { CompleteTodoOperation.call(todo_id: todo.id) }

    assert todo.reload.done
  end

  test 'an invite makes its redeemer a member of the list' do
    carol = User.create!

    assert_equal @list.id, redeem(invite, carol).list_id
    assert @list.memberships.member.exists?(account: carol)
  end

  test 'an invite is redeemed once' do
    code = invite
    redeem(code, User.create!)

    assert_raises(Kiosk::Server::Errors::Forbidden) { redeem(code, User.create!) }
  end

  test 'an invite is never redeemed after it expires' do
    code = invite

    travel(InviteOperation::TTL + 1.second) do
      assert_raises(Kiosk::Server::Errors::Forbidden) { redeem(code, User.create!) }
    end
  end

  test 'an owner redeeming her own invite stays the owner' do
    redeem(invite, @alice)

    assert @list.memberships.owner.exists?(account: @alice)
  end

  test 'only the owner removes a member' do
    as(@bob) do
      assert_raises(Kiosk::Server::Errors::Forbidden) { RemoveMemberOperation.call(list_id: @list.id, account_id: @alice.id) }
    end
    as(@alice) { RemoveMemberOperation.call(list_id: @list.id, account_id: @bob.id) }

    assert_not @list.memberships.exists?(account: @bob)
  end

  test 'the owner cannot remove themselves' do
    as(@alice) do
      error = assert_raises(Kiosk::Server::Errors::Forbidden) do
        RemoveMemberOperation.call(list_id: @list.id, account_id: @alice.id.upcase)
      end
      assert_equal 'the owner cannot remove themselves', error.message
    end
  end

  private

  def invite = as(@alice) { InviteOperation.call(member_id: @alice.id, list_id: @list.id) }
  def redeem(code, account) = as(account) { AcceptInviteOperation.call(member_id: account.id, code:) }
end
