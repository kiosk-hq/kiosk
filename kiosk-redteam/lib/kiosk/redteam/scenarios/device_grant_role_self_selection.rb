# frozen_string_literal: true

require 'openssl'

module Kiosk
  module Redteam
    module Scenarios
      # The unauthenticated device_authorization request must refuse a
      # client-chosen role or scope. Probed with roles the origin actually
      # declares, since a vulnerable origin refuses an undeclared one too; the
      # role-less request must still open the ceremony.
      class DeviceGrantRoleSelfSelection < Scenario
        # Refused by a vulnerable origin too; probed only to show both filters in the detail.
        UNDECLARED_ROLE = 'master'

        # RFC 8628 §3.2 user codes as this engine mints them.
        USER_CODE = /\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/

        def initialize
          super(
            name: 'DeviceGrantRoleSelfSelection',
            category: 'authorization',
            description: "The claim ceremony's unauthenticated opening request must refuse a " \
                         'client-chosen role — at a DECLARED value, under either spelling',
          )
        end

        def call(client, profile)
          wire_role, setup = wire_declared_role(client)
          return setup if setup

          declared = (profile.declared_roles + [wire_role]).compact.uniq
          return skip_verdict(no_declared_role_reason) if declared.empty?

          probes = probe(client, declared)
          control_ok, control_detail = control(client)
          refused = probes.all?(&:first)
          Verdict.new(blocked: refused && control_ok, skipped: false, status: refused ? 400 : 200,
                      detail: summary(probes, control_detail, declared, wire_role))
        end

        private

        # [refused?, detail] for each role or scope the request names.
        def probe(client, declared)
          pem = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
          probe_labels(declared).map do |label, param, value|
            resp = client.device_authorization(
              client_id: 'redteam-device-grant-role', public_key: pem, param => value
            )
            [resp.status == 400 && body_field(resp, 'error') == 'invalid_request',
             "#{label} -> HTTP #{resp.status} error=#{body_field(resp, 'error').inspect}"]
          end
        end

        def summary(probes, control_detail, declared, wire_role)
          "#{probes.map(&:last).join('; ')}; #{control_detail} " \
            "[declared roles probed: #{declared.inspect} " \
            "(#{wire_role.inspect} read off this origin's own registration token); " \
            'want every role/scope refused 400 invalid_request AND the role-less ' \
            'ceremony still opening]'
        end

        def body_field(resp, key)
          resp.body.is_a?(Hash) ? resp.body[key] : nil
        end

        def probe_labels(declared)
          declared.flat_map do |role|
            %i[role scope].map do |param|
              ["#{param}=#{role} (DECLARED by this origin — the escalation itself)", param, role]
            end
          end + %i[role scope].map do |param|
            ["#{param}=#{UNDECLARED_ROLE} (undeclared; refused by the vulnerable code too, " \
             'so it proves nothing alone)', param, UNDECLARED_ROLE]
          end
        end

        def control(client)
          key  = OpenSSL::PKey::RSA.generate(2048)
          resp = client.device_authorization(
            client_id: 'redteam-device-grant-role', public_key: key.public_key.to_pem
          )
          code = resp.body.is_a?(Hash) ? resp.body['user_code'].to_s : ''
          [resp.status == 200 && code.match?(USER_CODE),
           "CONTROL role-less request -> HTTP #{resp.status} user_code=#{code.inspect}"]
        end

        # The `role` claim of a token this origin mints at registration.
        def wire_declared_role(client)
          resp = client.register_raw
          failure = (registration_failure(resp) unless resp.status == 201)
          return [nil, failure] if failure

          [token_role(body_field(resp, 'access_token')), nil]
        end

        def registration_failure(resp)
          setup_failure(
            resp,
            step: 'the CONTROL registration this scenario reads a declared role from',
            because: 'without a role the origin actually declares, the only probe left is an ' \
                     'invented one — which even a vulnerable origin refuses, so the battery ' \
                     'would print BLOCKED without testing anything.'
          )
        end

        def no_declared_role_reason
          'this origin declares no role — `declared_roles` is empty in the profile AND the ' \
            'token it minted at registration carries no `role` claim, so a client-chosen ' \
            'DECLARED role has nothing to name here'
        end

        # Unverified: only what the server put there matters.
        def token_role(token)
          role = TokenClaims.claims(token)&.fetch('role', nil)
          role.nil? || role.to_s.empty? ? nil : role.to_s
        end
      end
    end
  end
end
