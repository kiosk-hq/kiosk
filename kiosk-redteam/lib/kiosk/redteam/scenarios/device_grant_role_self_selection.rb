# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module Kiosk
  module Redteam
    module Scenarios
      # Privilege self-selection at the ACCOUNT-BINDING CLAIM CEREMONY.
      #
      # {PrivilegeSelfSelection} is this scenario's sibling and covers the OTHER
      # door: `POST /auth/register`, where the role has always been pinned from
      # `config.registration_role` and the body is never read. This one covers
      # the door that was actually open — RFC 8628
      # `POST <endpoint>/oauth/device_authorization`, the UNAUTHENTICATED
      # request that opens the claim half of the binding ceremony.
      #
      # == Why this exists (K-072, and it is not a hypothetical)
      #
      # That request carries no Cookie and no Authorization header, so anything
      # in it is an assertion by a stranger. Until the K-072 fix the engine read
      # `role` (or its OAuth spelling `scope`) off it, wrote it onto the
      # authorization row, and baked it into the JWT the token poll returns —
      # with membership of `config.roles` as the ONLY filter. Measured on a
      # booted provider declaring two roles: a stranger's `role=owner` reached a
      # token whose `role` claim was `owner`, approved by a plain customer whose
      # consent page never showed the word.
      #
      # The role now comes from the APPROVING HUMAN's own identity, captured at
      # the verify page, and `role`/`scope` on the opening request are REFUSED
      # (400 `invalid_request`) rather than ignored — a silently dropped
      # parameter leaves the caller believing it got what it asked for.
      #
      # == Why the probe must name a DECLARED role
      #
      # The vulnerable code refused an UNDECLARED role: `config.roles` was the
      # filter, so `role=master` came back 400 then exactly as it does now. A
      # battery that injects only an invented role therefore CANNOT FAIL, and
      # prints BLOCKED against a live escalation — which is what
      # {PrivilegeSelfSelection}'s `ESCALATED_ROLE = "master"` did for the
      # nineteen days K-072 was open.
      #
      # So the probe set here is built from roles the origin actually HAS:
      #
      #   1. every role in `profile.declared_roles`, when the demo supplies them;
      #   2. PLUS one derived from the wire — the `role` claim of a token this
      #      origin mints for a freshly registered agent. That derivation is the
      #      floor that cannot go stale: an origin whose declared set grows
      #      while a hand-kept profile list does not is still probed with a real
      #      role, because the token is read from the provider under test rather
      #      than from a constant. (`config.roles` growing to two while the
      #      battery still described one is the precise shape of how K-072's
      #      recorded mitigation expired without anyone noticing.)
      #   3. PLUS {UNDECLARED_ROLE}, which proves nothing on its own and is kept
      #      only so the verdict line shows both filters answering.
      #
      # Each role is probed under BOTH spellings, `role=` and `scope=`, because
      # the vulnerable code read `params[:role] || params[:scope]` and a fix
      # that guarded one would leave the other.
      #
      # == Control
      #
      # A refusal is free: an origin that refused every `device_authorization`
      # would print BLOCKED here. So the same request WITHOUT the parameter must
      # still open the ceremony — 200 with a well-formed `XXXX-XXXX` user_code.
      #
      # Applicable to every provider: the binding ceremony is engine surface,
      # not a per-demo feature. Skipped only when the origin declares no role at
      # all, in which case there is no declared role for a client to name and
      # the escalation has nothing to escalate to.
      class DeviceGrantRoleSelfSelection < Scenario
        # A role no provider declares. On its own it proves NOTHING — the
        # vulnerable code refused it too. It is probed so the verdict detail
        # shows the declared and undeclared filters side by side.
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
          wire_role, setup = wire_declared_role(client, profile)
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

        # The probe list, as [label, param, value] triples.
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

        # The same request WITHOUT the parameter must still open the ceremony.
        def control(client)
          key  = OpenSSL::PKey::RSA.generate(2048)
          resp = client.device_authorization(
            client_id: "redteam-device-grant-role", public_key: key.public_key.to_pem,
          )
          code = resp.body.is_a?(Hash) ? resp.body["user_code"].to_s : ""
          [resp.status == 200 && code.match?(USER_CODE),
           "CONTROL role-less request -> HTTP #{resp.status} user_code=#{code.inspect}"]
        end

        # A role this origin genuinely declares, read off the wire rather than
        # from a constant: register an agent through the ordinary path (paying
        # the registration toll if there is one) and read the `role` claim of
        # the token the origin itself minted.
        #
        # Returns [role_or_nil, nil] on success and [nil, Verdict] when the
        # registration did not happen — a scenario that could not establish its
        # own probe set says so instead of falling back to the undeclared role,
        # which is the vacuous probe this whole file exists to replace.
        def wire_declared_role(client, profile)
          resp = client.register_raw(
            name: "redteam-device-grant-role", pow_difficulty: profile.pow_difficulty, pow: :solve,
          )
          if (failure = setup_failure(
            resp.status == 201 ? nil : resp,
            step:    "the CONTROL registration this scenario reads a declared role from",
            because: "without a role the origin actually declares, the only probe left is an " \
                     "invented one — which the vulnerable code refused too, so the battery " \
                     "would print BLOCKED without testing anything (K-072).",
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

        # Read the `role` claim from a JWS access token WITHOUT verifying it —
        # only what the server chose to put there matters.
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
