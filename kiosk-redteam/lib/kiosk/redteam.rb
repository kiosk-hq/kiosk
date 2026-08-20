# frozen_string_literal: true

require "kiosk/redteam/version"
require "kiosk/redteam/principal"
require "kiosk/redteam/response"
require "kiosk/redteam/verdict"
require "kiosk/redteam/client"
require "kiosk/redteam/scenario"
require "kiosk/redteam/runner"
require "kiosk/redteam/profile"

# Scenario library
require "kiosk/redteam/scenarios/cross_tenant_read"
require "kiosk/redteam/scenarios/forged_user_id"
require "kiosk/redteam/scenarios/mandate_principal_swap"
require "kiosk/redteam/scenarios/mandate_replay"
require "kiosk/redteam/scenarios/token_tampering"
require "kiosk/redteam/scenarios/registration_without_pow"
require "kiosk/redteam/scenarios/privilege_self_selection"
require "kiosk/redteam/scenarios/unpaid_gated_action"
require "kiosk/redteam/scenarios/missing_kyc"
require "kiosk/redteam/scenarios/expired_kyc"
require "kiosk/redteam/scenarios/forged_kyc"
require "kiosk/redteam/scenarios/spent_resource_reuse"
require "kiosk/redteam/scenarios/pay_for_other_use_self"

module Kiosk
  # Adversarial regression harness for Kiosk providers.
  #
  # Drive hostile HTTP scenarios against any Kiosk provider and assert each
  # attack is correctly blocked.  A scenario that finds a real breach fails
  # loudly — fix the provider, keep the scenario as a permanent regression.
  #
  # == Quick start
  #
  #   client  = Kiosk::Redteam::Client.new(base_url: "http://localhost:3001")
  #   runner  = Kiosk::Redteam::Runner.new(base_url: ..., profile: my_profile)
  #   results = runner.run(my_scenarios)
  #   exit 1 unless runner.all_blocked?
  #
  # == Blocked? semantics
  #
  # A Response is "blocked" when:
  #   - HTTP status is 401 or 403  (explicit auth/authz rejection), OR
  #   - the problem document's top-level `code` is one of the recognised
  #     domain denial codes
  #
  # A 5xx or connection error is NOT blocked — a crash cannot masquerade as a
  # successful enforcement gate.  Neither is a 402: see {PAYMENT_REQUIRED_CODES}.
  # Every other non-2xx is INDETERMINATE; scenarios should surface those as
  # leaks, not blocks.
  module Redteam
    # Canonical set of HTTP statuses that constitute a deliberate block.
    #
    # 402 is deliberately ABSENT (K-736) — see {PAYMENT_REQUIRED_CODES}. That
    # is unchanged by K-760: the harness now PAYS a PoW toll and re-sends, so a
    # 402 that still reaches here is one the retry could not settle.
    BLOCKED_STATUSES = [401, 403].freeze

    # The THREE problem-document `code`s kiosk-server maps onto HTTP 402
    # (`Kiosk::Server::Errors::CODES`), each with the reason it cannot be read
    # as "this attack was refused".  A bare 402 names none of them, and the
    # wire contract says so itself: `Errors::STATUS_CODES` deliberately omits
    # 402 because "three codes share it; guessing would put the wrong one on
    # the wire".  A harness that reads a refusal out of the bare status is
    # making exactly the inference the server refuses to make.
    PAYMENT_REQUIRED_CODES = {
      "pow_required" =>
        "a toll was DEMANDED, not a refusal — the request was deferred until a proof is " \
        "supplied. Since K-760 this harness PAYS that toll on every verb, so seeing this " \
        "code here means the demand survived a paid retry (or arrived with no challenges " \
        "to solve); either way the attack itself was never evaluated",
      "payment_setup_required" =>
        "the principal has no payment instrument on file — a gap in the ATTACKER's setup, " \
        "not a decision about the attack",
      "payment_failed" =>
        "the payment rail declined the charge AFTER the mandate trail verified — every " \
        "authorization gate the request passed through said yes; a declined card is not a gate",
    }.freeze

    # Domain error codes that constitute a deliberate block regardless of HTTP
    # status (some providers return 200 with an error envelope).
    # Note: "bad_request" (400) is intentionally excluded — a validation error
    # is NOT evidence of an auth/authz gate.  RegistrationWithoutPow uses its
    # own self-sufficient check instead of delegating to blocked?.
    # "pow_required" is excluded for the reason 402 is (K-736): a toll defers a
    # request, it does not refuse it.
    BLOCKED_ERROR_CODES = %w[forbidden unauthenticated rls_denied].freeze

    # Read the problem document's `code` defensively — the body may not be a
    # Hash at all (a successful query answers a bare ARRAY).
    #
    # @param response [Response]
    # @return [String, nil]
    # PROTOCOL 0.4: an error is an RFC 9457 problem document and the branch
    # point is the TOP-LEVEL `code` — a problem document is flat, so there is
    # no nested `error` object to reach into. The token VALUES are the same
    # closed vocabulary every verdict in this gem branches on, so nothing
    # above this seam changed.
    def self.error_code(response)
      body = response.body
      return nil unless body.is_a?(Hash)

      body["code"]
    end

    # Why this answer cannot settle a verdict on its own, or nil when it is not
    # a payment-required answer at all.
    #
    # Triggered by HTTP 402 whatever the envelope says, and by any of
    # {PAYMENT_REQUIRED_CODES} whatever the status says — a response whose
    # status and code disagree is the least conclusive of all.
    #
    # @param response [Response]
    # @return [String, nil]
    def self.payment_required_reason(response)
      code = error_code(response)
      return nil unless response.status == 402 || PAYMENT_REQUIRED_CODES.key?(code)

      why = PAYMENT_REQUIRED_CODES[code] ||
            "kiosk-server maps three codes onto 402 — #{PAYMENT_REQUIRED_CODES.keys.join(", ")} — " \
            "and this answer named none of them, so which gate fired (if any did) is unknowable"
      # K-760: distinguish "the harness does not pay tolls" from "the toll was
      # paid and demanded AGAIN". The first was a capability gap in this gem and
      # is gone; the second is the provider's behaviour and an operator needs to
      # be told which one they are looking at.
      paid = response.pow_retried ? " [the harness already solved every issued " \
                                    "challenge and re-sent the identical request once]" : ""
      "HTTP #{response.status} code=#{code.inspect}:#{paid} #{why}"
    end

    # Determine whether a provider response constitutes a successful block.
    #
    # Returns false for 5xx and connection-error responses so that a crash
    # can never be counted as "blocked" and mask a real breach.  The status
    # test comes FIRST and is absolute: until K-728 the denial-code branch had
    # no status guard, so a 500 whose body happened to carry `forbidden` — the
    # shape a crashing authorization filter renders — was counted as a block,
    # which is the one thing the paragraph above promises cannot happen.
    #
    # 402 answers false for the same family of reasons (K-736): two of the
    # three codes behind that status are not refusals of anything, and the
    # third is the payment rail's verdict rather than a gate's.  A scenario
    # that genuinely means a payment gate names the code it accepts —
    # {Scenario#verdict_from}'s `expect_code:` — instead of leaning on this
    # predicate, which has no way to tell the three apart for it.
    #
    # @param response [Response]
    # @return [Boolean]
    def self.blocked?(response)
      # status 0 is this gem's connection-error sentinel; >= 500 is a crash.
      return false if response.status >= 500 || response.status.zero?
      return false if payment_required_reason(response)
      return true if BLOCKED_STATUSES.include?(response.status)

      BLOCKED_ERROR_CODES.include?(error_code(response))
    end
  end
end
