# frozen_string_literal: true

require "kiosk/test_helpers/assistant"
require "kiosk/redteam/version"
require "kiosk/redteam/verdict"
require "kiosk/redteam/leak_scan"
require "kiosk/redteam/scenario"
require "kiosk/redteam/runner"
require "kiosk/redteam/profile"
require "kiosk/redteam/battery"

require "kiosk/redteam/scenarios/cross_tenant_read"
require "kiosk/redteam/scenarios/forged_user_id"
require "kiosk/redteam/scenarios/mandate_principal_swap"
require "kiosk/redteam/scenarios/mandate_replay"
require "kiosk/redteam/scenarios/token_tampering"
require "kiosk/redteam/scenarios/registration_without_pow"
require "kiosk/redteam/scenarios/privilege_self_selection"
require "kiosk/redteam/scenarios/device_grant_role_self_selection"
require "kiosk/redteam/scenarios/unpaid_gated_action"
require "kiosk/redteam/scenarios/missing_kyc"
require "kiosk/redteam/scenarios/expired_kyc"
require "kiosk/redteam/scenarios/forged_kyc"
require "kiosk/redteam/scenarios/spent_resource_reuse"
require "kiosk/redteam/scenarios/pay_for_other_use_self"
require "kiosk/redteam/scenarios/wrong_currency_cart"

module Kiosk
  # Adversarial regression harness: drives hostile HTTP scenarios against a
  # Kiosk origin and asserts each attack is refused.
  module Redteam
    # 402 is absent: see PAYMENT_REQUIRED_CODES.
    BLOCKED_STATUSES = [401, 403].freeze

    # The three codes kiosk-server maps onto HTTP 402, each with why it is not a refusal.
    PAYMENT_REQUIRED_CODES = {
      "pow_required" =>
        "a toll was DEMANDED, not a refusal — the request was deferred until a proof is " \
        "supplied. This harness PAYS that toll on every verb, so seeing this code here " \
        "means the demand survived a paid retry (or arrived with no challenges to " \
        "solve); either way the attack itself was never evaluated",
      "payment_setup_required" =>
        "the principal has no payment instrument on file — a gap in the ATTACKER's setup, " \
        "not a decision about the attack",
      "payment_failed" =>
        "the payment rail declined the charge AFTER the mandate trail verified — every " \
        "authorization gate the request passed through said yes; a declined card is not a gate",
    }.freeze

    # A validation error (bad_request) is not evidence of an authorization gate.
    BLOCKED_ERROR_CODES = %w[forbidden unauthenticated rls_denied].freeze

    # A successful query answers a bare Array, so the body may not be a Hash.
    def self.error_code(response)
      body = response.body
      return nil unless body.is_a?(Hash)

      body["code"]
    end

    # Why a payment-required answer cannot settle a verdict, or nil when it is not one.
    def self.payment_required_reason(response)
      code = error_code(response)
      return nil unless response.status == 402 || PAYMENT_REQUIRED_CODES.key?(code)

      why = PAYMENT_REQUIRED_CODES[code] ||
            "kiosk-server maps three codes onto 402 — #{PAYMENT_REQUIRED_CODES.keys.join(", ")} — " \
            "and this answer named none of them, so which gate fired (if any did) is unknowable"
      paid = response.pow_retried ? " [the harness already solved every issued " \
                                    "challenge and re-sent the identical request once]" : ""
      "HTTP #{response.status} code=#{code.inspect}:#{paid} #{why}"
    end

    def self.blocked?(response)
      # Status first: a crash whose body carries `forbidden` is not a block. 0 is a connection error.
      return false if response.status >= 500 || response.status.zero?
      return false if payment_required_reason(response)
      return true if BLOCKED_STATUSES.include?(response.status)

      BLOCKED_ERROR_CODES.include?(error_code(response))
    end
  end
end
