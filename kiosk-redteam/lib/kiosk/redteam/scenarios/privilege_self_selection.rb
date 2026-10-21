# frozen_string_literal: true

require 'openssl'

module Kiosk
  module Redteam
    module Scenarios
      # A role injected into the registration body must not reach the token
      # that the client then gets. A refusal counts only if the same
      # registration without the role succeeds.
      class PrivilegeSelfSelection < Scenario
        ESCALATED_ROLE = 'master'

        def initialize
          super(name: 'PrivilegeSelfSelection')
        end

        def call(client, _profile)
          key  = OpenSSL::PKey::RSA.generate(2048)
          resp = client.register_raw(wire_role: ESCALATED_ROLE, key:)
          return refusal_verdict(client, resp) unless resp.status == 201

          issued = client.token(registered_principal(resp, key))
          setup_failure(issued, step: 'the token request after the registration with the injected role',
                                because: 'without a token there is no role to read.') || role_verdict(issued)
        end

        private

        def role_verdict(issued)
          role = TokenClaims.claims(issued.body['access_token'])&.fetch('role', nil)
          return blocked_verdict(201) unless [role, issued.body['scope']].include?(ESCALATED_ROLE)

          breach_verdict(issued.status, "issued token carries the self-selected role #{ESCALATED_ROLE.inspect}")
        end

        def refusal_verdict(client, resp)
          if resp.status >= 500 || resp.status.zero?
            return breach_verdict(resp.status,
                                  "register crashed on the injected role (HTTP #{resp.status}: " \
                                  "#{resp.body.inspect}) — a crash is not a gate")
          end

          control_failure(client.register_raw, resp) || blocked_verdict(resp.status)
        end

        def control_failure(control, resp)
          return nil if control.status == 201 && control.body.is_a?(Hash) && control.body['client_id']

          breach_verdict(control.status,
                         'CONTROL FAILED: an honest registration must return 201 with a ' \
                         "client_id — got HTTP #{control.status} #{control.body.inspect}. " \
                         "The injected registration's HTTP #{resp.status} refusal therefore " \
                         'says nothing about whether the role is pinned server-side.')
        end
      end
    end
  end
end
