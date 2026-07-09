# frozen_string_literal: true

require "base64"
require "json"

module Kiosk
  module Redteam
    module Scenarios
      # Privilege self-selection at registration.
      #
      # The agent role becomes a `SET LOCAL` GUC that every RLS policy trusts,
      # so honouring a CLIENT-chosen role at registration would be a
      # privilege-escalation primitive. The role must be pinned server-side.
      #
      # Attack:
      #   1. Register while injecting `role: "master"` into the /auth/register
      #      body — a role the provider did not grant this agent.
      #   2. BREACH iff the issued access_token carries that escalated role.
      #      BLOCKED iff the server ignored it (issued role != "master") or
      #      refused the registration outright.
      #
      # Always applicable — every provider pins the registration role.
      class PrivilegeSelfSelection < Scenario
        ESCALATED_ROLE = "master"

        def initialize
          super(
            name:        "PrivilegeSelfSelection",
            category:    "authorization",
            description: "A client-chosen registration role must be ignored (role is server-pinned)",
          )
        end

        def call(client, profile)
          resp = client.register_raw(
            name:           "redteam-priv-escalation",
            pow_difficulty: profile.pow_difficulty,
            pow:            :solve,
            wire_role:      ESCALATED_ROLE,
          )

          # A refusal (non-201, no token) also means no escalation happened.
          return blocked_verdict(resp.status) unless resp.status == 201

          token       = resp.body.is_a?(Hash) ? resp.body["access_token"] : nil
          issued_role = token && token_role(token)

          if issued_role == ESCALATED_ROLE
            Verdict.new(
              blocked: false, skipped: false, status: 201,
              detail:  "issued token carries the self-selected role #{ESCALATED_ROLE.inspect}",
            )
          else
            blocked_verdict(201)
          end
        end

        private

        def blocked_verdict(status)
          Verdict.new(blocked: true, skipped: false, status: status, detail: "")
        end

        # Read the `role` claim from a JWS access token WITHOUT verifying it — we
        # only care what the server chose to put there.
        def token_role(token)
          payload_b64 = token.to_s.split(".")[1]
          return nil if payload_b64.nil?

          padded = payload_b64 + ("=" * ((4 - payload_b64.length % 4) % 4))
          JSON.parse(Base64.urlsafe_decode64(padded))["role"]
        rescue StandardError
          nil
        end
      end
    end
  end
end
