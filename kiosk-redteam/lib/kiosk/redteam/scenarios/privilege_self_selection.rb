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
      #      refused the registration outright — but a refusal counts ONLY once
      #      a CONTROL registration, identical but for the injected role, has
      #      returned 201 with a token (K-730).
      #
      # Without that control a refusal is free: a server that refuses every
      # registration refuses the escalation too, and this scenario was
      # demonstrated printing BLOCKED against one answering 404 on every path.
      # The control is fetched lazily — only on the refusal branch — so the
      # normal case (201, role pinned) still costs a single registration.
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

          # A refusal (non-201, no token) also means no escalation happened —
          # provided registration works here at all.
          return refusal_verdict(client, profile, resp) unless resp.status == 201

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

        # The injected registration was refused.  That is role-pinning only if
        # the SAME registration without the injected role succeeds; a crash is
        # never a gate, and a server refusing everything is not one either.
        def refusal_verdict(client, profile, resp)
          if resp.status >= 500 || resp.status.zero?
            return Verdict.new(
              blocked: false, skipped: false, status: resp.status,
              detail:  "register crashed on the injected role (HTTP #{resp.status}: " \
                       "#{resp.body.inspect}) — a crash is not a gate",
            )
          end

          control = client.register_raw(
            name:           "redteam-priv-control",
            pow_difficulty: profile.pow_difficulty,
            pow:            :solve,
          )
          control_token = control.body.is_a?(Hash) ? control.body["access_token"] : nil
          unless control.status == 201 && control_token
            return Verdict.new(
              blocked: false, skipped: false, status: control.status,
              detail:  "CONTROL FAILED: an honest registration must return 201 with an " \
                       "access_token — got HTTP #{control.status} #{control.body.inspect}. " \
                       "The injected registration's HTTP #{resp.status} refusal therefore " \
                       "says nothing about whether the role is pinned server-side.",
            )
          end

          blocked_verdict(resp.status)
        end

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
