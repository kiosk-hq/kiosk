# frozen_string_literal: true

require 'test_helper'

# The public page that mirrors the seeded housemate's lists.
class HousemateBoardTest < ActionDispatch::IntegrationTest
  setup do
    bob   = User.create!(id: ListsController::HOUSEMATE_ID, email: 'bob@example.test', password: 'board-fixture-password')
    alice = User.create!(email: 'alice@example.test', password: 'board-fixture-password', display_name: 'Alice')
    list  = CreateListOperation.call(member_id: alice.id, title: 'Groceries')
    list.memberships.create!(account: bob, role: :member)
    list.todos.create!(title: 'Milk', created_at: 2.minutes.ago)
    list.todos.create!(title: 'Bread', done: true)
    get '/shared'
  end

  test 'the board names each list the housemate is on and who shared it' do
    assert_select '.board-item-title', text: 'Groceries'
    assert_select '.board-item-role', text: 'member'
    assert_select '.board-item-shared', text: /shared by Alice/
  end

  test "the board lists a list's tasks oldest first and marks the done ones" do
    assert_equal %w[Milk Bread], css_select('.board-task-title').map(&:text)
    assert_select '.board-task.is-done .board-task-title', text: 'Bread'
  end
end
