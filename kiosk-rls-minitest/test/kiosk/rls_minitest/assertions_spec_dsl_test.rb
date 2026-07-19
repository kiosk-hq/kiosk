# frozen_string_literal: true

require "test_helper"

# Exercises the four spec-DSL bridge forms registered via
# `infect_an_assertion` (assertions.rb) — `must_raise_rls_denied`,
# `must_raise_quota_exceeded`, `wont_raise_rls_denied`,
# `wont_raise_quota_exceeded` — promised by README.md and the gemspec but
# otherwise untested. Uses Minitest's spec runner so
# `Minitest::Spec.current` is the ctx the infected expectation delegates to,
# and `include Kiosk::TestHelpers` gives that spec instance the underlying
# `assert_*` / `refute_*` assertions.
describe "Kiosk spec-DSL assertion bridges" do
  include Kiosk::TestHelpers

  RLSDenied     = Kiosk::TestHelpers::Errors::RLSDenied
  QuotaExceeded = Kiosk::TestHelpers::Errors::QuotaExceeded

  it "must_raise_rls_denied passes when the block raises RLSDenied" do
    _ { raise RLSDenied }.must_raise_rls_denied
  end

  it "must_raise_rls_denied flunks when the block raises nothing" do
    assert_raises(Minitest::Assertion) do
      _ { 1 + 1 }.must_raise_rls_denied
    end
  end

  it "must_raise_quota_exceeded passes when the block raises QuotaExceeded" do
    _ { raise QuotaExceeded }.must_raise_quota_exceeded
  end

  it "wont_raise_rls_denied passes when the block raises nothing" do
    _ { 1 + 1 }.wont_raise_rls_denied
  end

  it "wont_raise_rls_denied flunks when the block raises RLSDenied" do
    assert_raises(Minitest::Assertion) do
      _ { raise RLSDenied }.wont_raise_rls_denied
    end
  end

  it "wont_raise_quota_exceeded passes when the block raises nothing" do
    _ { 1 + 1 }.wont_raise_quota_exceeded
  end
end
