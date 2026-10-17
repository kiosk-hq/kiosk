# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # A role injected into /auth/register must not reach the issued token.
      # A refusal counts only if the same registration without the role succeeds.
      class PrivilegeSelfSelection < Scenario
        ESCALATED_ROLE = 'master'

        def initialize
          super(
            name: 'PrivilegeSelfSelection',
            category: 'authorization',
            description: 'A client-chosen registration role must be ignored (role is server-pinned)',
          )
        end

        def call(client, _profile)
          resp = client.register_raw(wire_role: ESCALATED_ROLE)
          return refusal_verdict(client, resp) unless resp.status == 201
          return blocked_verdict(201) unless TokenClaims.claims(access_token(resp))&.fetch('role', nil) == ESCALATED_ROLE

          breach_verdict(201, "issued token carries the self-selected role #{ESCALATED_ROLE.inspect}")
        end

        private

        def refusal_verdict(client, resp)
          if resp.status >= 500 || resp.status.zero?
            return breach_verdict(resp.status,
                                  "register crashed on the injected role (HTTP #{resp.status}: " \
                                  "#{resp.body.inspect}) — a crash is not a gate")
          end

          control_failure(client.register_raw, resp) || blocked_verdict(resp.status)
        end

        def control_failure(control, resp)
          return nil if control.status == 201 && access_token(control)

          breach_verdict(control.status,
                         'CONTROL FAILED: an honest registration must return 201 with an ' \
                         "access_token — got HTTP #{control.status} #{control.body.inspect}. " \
                         "The injected registration's HTTP #{resp.status} refusal therefore " \
                         'says nothing about whether the role is pinned server-side.')
        end

        def access_token(resp)
          resp.body.is_a?(Hash) ? resp.body['access_token'] : nil
        end
      end
    end
  end
end
