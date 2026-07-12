# frozen_string_literal: true

require "test_helper"

class AssertionsTest < Minitest::Test
  include Kiosk::TestHelpers

  def test_assert_rls_denied_passes_when_block_raises_rls_denied
    assert_rls_denied { raise Kiosk::TestHelpers::Errors::RLSDenied }
  end

  def test_assert_rls_denied_flunks_when_block_raises_nothing
    err = assert_raises(Minitest::Assertion) do
      assert_rls_denied { 1 + 1 }
    end
    assert_match(/no exception/, err.message)
  end

  def test_assert_rls_denied_flunks_when_block_raises_other_error
    err = assert_raises(Minitest::Assertion) do
      assert_rls_denied { raise ArgumentError, "boom" }
    end
    assert_match(/ArgumentError/, err.message)
  end

  def test_refute_rls_denied_passes_when_block_raises_nothing
    refute_rls_denied { 1 + 1 }
  end

  def test_refute_rls_denied_flunks_when_block_raises_rls_denied
    assert_raises(Minitest::Assertion) do
      refute_rls_denied { raise Kiosk::TestHelpers::Errors::RLSDenied }
    end
  end

  def test_assert_quota_exceeded_passes
    assert_quota_exceeded { raise Kiosk::TestHelpers::Errors::QuotaExceeded }
  end

  def test_assert_quota_exceeded_flunks_on_different_error
    assert_raises(Minitest::Assertion) do
      assert_quota_exceeded { raise Kiosk::TestHelpers::Errors::RLSDenied }
    end
  end

  def test_refute_quota_exceeded_passes_when_block_raises_nothing
    refute_quota_exceeded { 1 + 1 }
  end

  def test_refute_quota_exceeded_flunks_when_block_raises_quota_exceeded
    err = assert_raises(Minitest::Assertion) do
      refute_quota_exceeded { raise Kiosk::TestHelpers::Errors::QuotaExceeded, "over limit" }
    end
    assert_match(/not to raise QuotaExceeded/, err.message)
  end

  def test_end_to_end_assert_rls_denied_with_null_executor
    Kiosk::TestHelpers.executor.enqueue_error(:query, :rls_denied)
    assert_rls_denied { Kiosk::TestHelpers.executor.query("select 1") }
  end

  def test_end_to_end_assert_quota_exceeded_with_null_executor
    Kiosk::TestHelpers.executor.enqueue_error(:run_action, :quota_exceeded)
    assert_quota_exceeded { Kiosk::TestHelpers.executor.run_action(:x, {}) }
  end
end
