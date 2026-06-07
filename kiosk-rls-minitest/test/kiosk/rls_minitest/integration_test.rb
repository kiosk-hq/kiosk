# frozen_string_literal: true

require "test_helper"

# Exercise the documented entry point from spec §12: a Minitest test class
# that does `include Kiosk::TestHelpers` should get both the journey DSL
# and the Kiosk assertions, in one include.
class IntegrationJourneyTest < Minitest::Test
  include Kiosk::TestHelpers

  def setup
    super
    Kiosk.configure { |c| c.roles = %i[customer master] }
    @alice = FakeUser.new("u-alice", "customer")
  end

  def test_journey_helpers_are_available
    assert_respond_to self, :as_agent_of
    assert_respond_to self, :as_user
    assert_respond_to self, :as_agent
    assert_respond_to self, :as_anonymous
    assert_respond_to self, :query
    assert_respond_to self, :run_action
    assert_respond_to self, :pay_action
    assert_respond_to self, :kiosk_seed
  end

  def test_assertions_are_available
    assert_respond_to self, :assert_rls_denied
    assert_respond_to self, :assert_quota_exceeded
    assert_respond_to self, :refute_rls_denied
    assert_respond_to self, :refute_quota_exceeded
  end

  def test_as_agent_of_scopes_identity
    observed = nil
    as_agent_of(@alice) { observed = Kiosk::TestHelpers.executor.current_identity }
    assert_equal "agent",   observed.actor
    assert_equal "u-alice", observed.user_id
  end

  def test_as_user_scopes_identity_without_agent_id
    as_user(@alice) do
      ident = Kiosk::TestHelpers.executor.current_identity
      assert_equal "human", ident.actor
      assert_nil   ident.agent_id
    end
  end

  def test_query_delegates_to_executor
    Kiosk::TestHelpers.executor.enqueue_query([{ "n" => 1 }])
    result = as_user(@alice) { query("select 1") }
    assert_equal [{ "n" => 1 }], result
  end

  def test_kiosk_seed_expands_owner_to_user_id
    kiosk_seed(:rentals, owner: @alice)
    call = Kiosk::TestHelpers.executor.calls_of(:seed).first
    assert_equal({ user_id: "u-alice" }, call.args[:attrs])
  end

  def test_executor_not_configured_raises
    Kiosk::TestHelpers.reset!
    assert_raises(Kiosk::TestHelpers::Errors::ExecutorNotConfigured) do
      as_agent_of(@alice) {}
    end
  end
end
