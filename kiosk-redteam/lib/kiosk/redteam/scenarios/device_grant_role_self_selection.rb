# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module Kiosk
  module Redteam
    module Scenarios
      # The unauthenticated device_authorization request must refuse a
      # client-chosen role or scope. Probed with roles the origin actually
      # declares, since a vulnerable origin refuses an undeclared one too; the
      # role-less request must still open the ceremony.
      class DeviceGrantRoleSelfSelection < Scenario
        # Refused by a vulnerable origin too; probed only to show both filters in the detail.
        UNDECLARED_ROLE = "master"

        # RFC 8628 §3.2 user codes as this engine mints them.
        USER_CODE = /\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/

        def initialize
          super(
            name:        "DeviceGrantRoleSelfSelection",
            category:    "authorization",
            description: "The claim ceremony's unauthenticated opening request must refuse a " \
                         "client-chosen role — at a DECLARED value, under either spelling",
          )
        end

        def call(client, profile)
          wire_role, setup = wire_declared_role(client)
          return setup if setup

          declared = (profile.declared_roles + [wire_role]).compact.uniq
          return skip_verdict(no_declared_role_reason) if declared.empty?

          key = OpenSSL::PKey::RSA.generate(2048)
          pem = key.public_key.to_pem

          probes = probe_labels(declared).map do |label, param, value|
            resp = client.device_authorization(
              client_id: "redteam-device-grant-role", public_key: pem, param => value,
            )
            refused = resp.status == 400 && resp.body.is_a?(Hash) &&
                      resp.body["error"] == "invalid_request"
            [refused, "#{label} -> HTTP #{resp.status} " \
                      "error=#{(resp.body.is_a?(Hash) ? resp.body["error"] : nil).inspect}"]
          end

          control_ok, control_detail = control(client)

          Verdict.new(
            blocked: probes.all?(&:first) && control_ok,
            skipped: false,
            status:  probes.all?(&:first) ? 400 : 200,
            detail:  "#{probes.map(&:last).join("; ")}; #{control_detail} " \
                     "[declared roles probed: #{declared.inspect} " \
                     "(#{wire_role.inspect} read off this origin's own registration token); " \
                     "want every role/scope refused 400 invalid_request AND the role-less " \
                     "ceremony still opening]",
          )
        end

        private

        def probe_labels(declared)
          declared.flat_map do |role|
            %i[role scope].map do |param|
              ["#{param}=#{role} (DECLARED by this origin — the escalation itself)", param, role]
            end
          end + %i[role scope].map do |param|
            ["#{param}=#{UNDECLARED_ROLE} (undeclared; refused by the vulnerable code too, " \
             "so it proves nothing alone)", param, UNDECLARED_ROLE]
          end
        end

        def control(client)
          key  = OpenSSL::PKey::RSA.generate(2048)
          resp = client.device_authorization(
            client_id: "redteam-device-grant-role", public_key: key.public_key.to_pem,
          )
          code = resp.body.is_a?(Hash) ? resp.body["user_code"].to_s : ""
          [resp.status == 200 && code.match?(USER_CODE),
           "CONTROL role-less request -> HTTP #{resp.status} user_code=#{code.inspect}"]
        end

        # The `role` claim of a token this origin mints at registration.
        def wire_declared_role(client)
          resp = client.register_raw
          if (failure = setup_failure(
            resp.status == 201 ? nil : resp,
            step:    "the CONTROL registration this scenario reads a declared role from",
            because: "without a role the origin actually declares, the only probe left is an " \
                     "invented one — which even a vulnerable origin refuses, so the battery " \
                     "would print BLOCKED without testing anything.",
          ))
            return [nil, failure]
          end

          token = resp.body.is_a?(Hash) ? resp.body["access_token"] : nil
          [token_role(token), nil]
        end

        def no_declared_role_reason
          "this origin declares no role — `declared_roles` is empty in the profile AND the " \
            "token it minted at registration carries no `role` claim, so a client-chosen " \
            "DECLARED role has nothing to name here"
        end

        # Unverified: only what the server put there matters.
        def token_role(token)
          payload_b64 = token.to_s.split(".")[1]
          return nil if payload_b64.nil?

          padded = payload_b64 + ("=" * ((4 - payload_b64.length % 4) % 4))
          role = JSON.parse(Base64.urlsafe_decode64(padded))["role"]
          role.nil? || role.to_s.empty? ? nil : role.to_s
        rescue StandardError
          nil
        end
      end
    end
  end
end
