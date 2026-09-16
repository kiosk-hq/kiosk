# frozen_string_literal: true

require "test_helper"

# THE AGE-CHECK CAP METERS OPEN INTAKES; IT MAY NEVER CLOSE AN ACCOUNT DOWN.
#
# `request_kyc` caps how many verifications one account may have open at the
# broker, because without it one registration proof buys unlimited intakes. The
# cap counts PENDING rows — and a row only ever leaves `pending` when the BROKER
# CALLS BACK, which it does on an approval and on nothing else. A human who
# refuses the check, or closes the tab, leaves a row that nothing can move: no
# callback, no TTL, no sweeper. Three of those and the shelf is shut for good,
# with a refusal that says the opposite.
#
# So the count is over intakes that are still LIVE, and the two examples below
# are the two halves of that: the cap still bites on three open pages, and it
# lets the account back in once they are old enough that nobody is going to
# finish them.
class RequestKycCapTest < ActiveSupport::TestCase
  setup do
    @shopper = User.create!(email: "capped@example.test", password: "conformance-fixture-password")
  end

  test "three verifications opened just now use the cap up" do
    3.times { |i| open_intake(i, age: 1.minute) }

    refusal = assert_kiosk_refused { request_kyc }
    assert_equal "quota_exceeded", refusal.code
    assert_equal 429, refusal.http_status
  end

  test "verifications nobody finished stop counting, so the account is not walled out" do
    3.times { |i| open_intake(i, age: RequestKycOperation::OUTSTANDING_WINDOW + 1.minute) }

    # No broker is configured here, so the call CANNOT succeed — what matters is
    # WHICH refusal it gets: reaching the broker's absence means the cap let it
    # through, which is the whole assertion.
    refusal = assert_kiosk_refused { request_kyc }
    refute_equal "quota_exceeded", refusal.code,
                 "an intake nobody can finish any more must not hold the account out"
    assert_equal "module_not_served", refusal.code
  end

  test "an approved verification stops counting the moment it lands" do
    3.times { |i| open_intake(i, age: 1.minute) }
    KycVerificationRequest.where(request_token: "intake-0")
                          .update_all(status: KycVerificationRequest::APPROVED)

    refusal = assert_kiosk_refused { request_kyc }
    assert_equal "module_not_served", refusal.code
  end

  private

  def request_kyc = kiosk_origin.call("request_kyc", kind: :action, params: {}, as: @shopper)

  # What an unfinished broker page leaves behind here: one `pending` row and
  # nothing else. `insert!` with an explicit `created_at`, because the age of
  # the row is the fact under test.
  def open_intake(index, age:)
    opened = age.ago
    KycVerificationRequest.insert!(
      { request_token: "intake-#{index}", user_id: @shopper.id, broker_nonce: "nonce-#{index}",
        status: KycVerificationRequest::PENDING, created_at: opened, updated_at: opened },
    )
  end
end
