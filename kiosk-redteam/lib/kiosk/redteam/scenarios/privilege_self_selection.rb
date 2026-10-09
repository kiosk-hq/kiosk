# frozen_string_literal: true

require "base64"
require "json"

module Kiosk
  module Redteam
    module Scenarios
      # A role injected into /auth/register must not reach the issued token.
      # A refusal counts only if the same registration without the role succeeds.
      class PrivilegeSelfSelection < Scenario
        ESCALATED_ROLE = "master"

        def initialize
          super(
            name:        "PrivilegeSelfSelection",
            category:    "authorization",
            description: "A client-chosen registration role must be ignored (role is server-pinned)",
          )
        end

        def call(client, _profile)
          resp = client.register_raw(wire_role: ESCALATED_ROLE)

          return refusal_verdict(client, resp) unless resp.status == 201

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

        def refusal_verdict(client, resp)
          if resp.status >= 500 || resp.status.zero?
            return Verdict.new(
              blocked: false, skipped: false, status: resp.status,
              detail:  "register crashed on the injected role (HTTP #{resp.status}: " \
                       "#{resp.body.inspect}) — a crash is not a gate",
            )
          end

          control = client.register_raw
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

        # Unverified: only what the server put there matters.
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
