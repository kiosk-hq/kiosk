# frozen_string_literal: true

require "kiosk/redteam/version"
require "kiosk/redteam/principal"
require "kiosk/redteam/response"
require "kiosk/redteam/verdict"
require "kiosk/redteam/client"
require "kiosk/redteam/scenario"
require "kiosk/redteam/runner"
require "kiosk/redteam/profile"

# Scenario library (Task 2)
require "kiosk/redteam/scenarios/cross_tenant_read"
require "kiosk/redteam/scenarios/forged_user_id"
require "kiosk/redteam/scenarios/mandate_principal_swap"
require "kiosk/redteam/scenarios/mandate_replay"
require "kiosk/redteam/scenarios/token_tampering"
require "kiosk/redteam/scenarios/registration_without_pow"
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
  #   - HTTP status is 401, 402, or 403  (explicit auth/authz rejection), OR
  #   - body["error"]["code"] is one of the recognised domain denial codes
  #
  # A 5xx or connection error is NOT blocked — a crash cannot masquerade as a
  # successful enforcement gate.  Non-2xx / non-{401-403} responses are
  # INDETERMINATE; scenarios should surface them as leaks, not blocks.
  module Redteam
    # Canonical set of HTTP statuses that constitute a deliberate block.
    BLOCKED_STATUSES = [401, 402, 403].freeze

    # Domain error codes that constitute a deliberate block regardless of HTTP
    # status (some providers return 200 with an error envelope).
    BLOCKED_ERROR_CODES = %w[forbidden unauthenticated pow_required rls_denied bad_request].freeze

    # Determine whether a provider response constitutes a successful block.
    #
    # Returns false for 5xx and connection-error responses so that a crash
    # can never be counted as "blocked" and mask a real breach.
    #
    # @param response [Response]
    # @return [Boolean]
    def self.blocked?(response)
      return true if BLOCKED_STATUSES.include?(response.status)

      # Safely navigate body["error"]["code"] — body["error"] may be a String
      # (plain message) rather than a Hash when the server returns a simple
      # error envelope.  Guard against TypeError from String#dig absence.
      body = response.body
      if body.is_a?(Hash)
        error = body["error"]
        if error.is_a?(Hash)
          return true if BLOCKED_ERROR_CODES.include?(error["code"])
        end
      end

      false
    end
  end
end
