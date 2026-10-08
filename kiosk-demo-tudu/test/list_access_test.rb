# frozen_string_literal: true

require "test_helper"

class ListAccessTest < ActiveSupport::TestCase
  setup { @alice, @bob, @list = household }

  test "a member reaches the list, and only its owner may manage it" do
    as(@bob) do
      assert_nil ListAccess.member!(@list.id)
      error = assert_raises(Kiosk::Server::Errors::Forbidden) { ListAccess.owner!(@list.id) }
      assert_equal "list not owned by the authenticated principal", error.message
    end
    as(@alice) { assert_nil ListAccess.owner!(@list.id) }
  end

  test "a stranger is refused alike for a foreign list, an unknown one and a malformed id" do
    stranger = User.create!
    as(stranger) do
      [@list.id, SecureRandom.uuid, "not-a-uuid"].each do |list_id|
        error = assert_raises(Kiosk::Server::Errors::Forbidden) { ListAccess.member!(list_id) }
        assert_equal "list not accessible by the authenticated principal", error.message
      end
    end
  end
end
