# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Forged user_id injection: the server must ignore caller-supplied user_id.
      #
      # Attack:
      #   1. A and B register.
      #   2. B calls profile.forge_action with user_id: A.user_id injected into
      #      the args.  A well-hardened server overwrites user_id from the
      #      authenticated token, so the resource is created under B.
      #   3. We then query A's rows (profile.per_user_query).  If A sees the
      #      new resource, the forged id was honoured → BREACH.
      #      If the call was rejected outright (4xx) → BLOCKED.
      #      If A does not see the resource → BLOCKED (id was stripped).
      #
      # Skipped when: profile.forge_action or profile.forge_args is nil.
      class ForgedUserId < Scenario
        # The argument this scenario injects. It is a constant rather than a
        # profile field because the ATTACK is "claim another principal", and
        # `user_id` is the name the protocol gives a principal everywhere it
        # appears — in an access token's claims, in a mandate, in the session
        # GUCs. A provider free to rename it could not be attacked by any
        # generic prober.
        FORGED_ARG = "user_id"

        def initialize
          super(
            name:        "ForgedUserId",
            category:    "authorization",
            description: "An agent-supplied user_id must never decide ownership: the server " \
                         "either refuses the argument outright or ignores it and takes the " \
                         "principal from the access token",
          )
        end

        def call(client, profile)
          return skip_verdict("no forge_action") unless profile.forge_action
          return skip_verdict("no forge_args")   unless profile.forge_args

          a = register_principal(client, name: "redteam-fui-a", profile:)
          b = register_principal(client, name: "redteam-fui-b", profile:)

          base_args   = profile.forge_args.call(client, a, b)
          forged_args = base_args.merge(FORGED_ARG.to_sym => a.user_id)

          resp = client.run(b, name: profile.forge_action, **forged_args)

          # A 402 answered nothing: a toll fires ahead of the handler, and a
          # payment_setup_required means B never had a card. Neither says
          # whether the injected user_id would have been honoured, and the
          # ownership check below cannot run either — there is no new resource
          # to look for. Say could-not-test rather than reading the rest of this
          # method's silence as a pass (K-736).
          stall = payment_required_stall(resp, step: "the forged-user_id #{profile.forge_action} call")
          return stall if stall

          # THE SCHEMA LAYER IS A LEGITIMATE PLACE TO CATCH THIS, and since
          # protocol 0.4 it is where a conformant origin catches it FIRST.
          #
          # §8.1 item 5 makes the operator validate every call against the
          # verb's declared `input_schema` before the handler runs, and a verb
          # whose principal comes from the token does not declare a `user_id`
          # parameter — so an origin publishing `additionalProperties: false`
          # answers `400 bad_request` NAMING the injected property. That is the
          # attack refused, at the outermost layer, by a published contract.
          #
          # `blocked?` cannot say so and must not be taught to: it excludes
          # `bad_request` on purpose, because a validation error in general is
          # not evidence of an auth gate (K-728). What makes THIS 400 evidence
          # is the one thing a generic predicate cannot check — that the refusal
          # names the property we injected. So the check lives here, where the
          # injected name is known, and nowhere else.
          if resp.status == 400 && Kiosk::Redteam.error_code(resp) == "bad_request" &&
             refusal_names?(resp, FORGED_ARG)
            return Verdict.new(
              blocked: true,
              skipped: false,
              status:  resp.status,
              detail:  "forge_action refused by the declared input contract: 400 bad_request naming " \
                       "#{FORGED_ARG.inspect} — the principal is not an accepted argument",
            )
          end

          # If the call was rejected outright, the server caught it — but only
          # an auth/authz refusal is "caught it" (K-728).
          # 401 and 403 are both admitted: a provider may treat a caller
          # claiming another principal as unauthenticated rather than forbidden.
          if Kiosk::Redteam.blocked?(resp)
            return verdict_from(resp, expect: [401, 403], detail: "forge_action rejected")
          end

          # Call succeeded — check whether A's per_user_query now contains the
          # resource.  If per_user_query is unavailable, we cannot verify
          # ownership at all — treat as indeterminate breach (conservative).
          unless profile.per_user_query
            return Verdict.new(
              blocked: false,
              skipped: false,
              status:  resp.status,
              detail:  "forge_action returned #{resp.status}; cannot verify ownership (no per_user_query)",
            )
          end

          # Extract the new resource id from the action response using
          # profile.result_id_key (no provider names hard-coded here).
          new_id = extract_id(resp, profile.result_id_key)

          # If we cannot extract the id we cannot positively confirm the server
          # IGNORED the forged user_id — score as indeterminate breach so the
          # test fails loud rather than silently passing.
          unless new_id
            return Verdict.new(
              blocked: false,
              skipped: false,
              status:  resp.status,
              detail:  "forge_action returned #{resp.status} but result_id_key=#{profile.result_id_key.inspect} " \
                       "not found in response; cannot confirm ownership was enforced",
            )
          end

          query_resp = client.query(a, name: profile.per_user_query)
          a_rows     = rows_from(query_resp)
          leaked     = a_rows.any? { |r| r[profile.row_id_key].to_s == new_id.to_s }

          if leaked
            Verdict.new(
              blocked: false,
              skipped: false,
              status:  resp.status,
              detail:  "forged user_id=#{a.user_id} was honoured; resource id=#{new_id} visible in A's rows",
            )
          else
            Verdict.new(blocked: true, skipped: false, status: resp.status, detail: "")
          end
        end

        private

        # Try to extract the resource id from the action response body using
        # the profile-supplied result_id_key.  No provider names are hard-coded.
        #
        # @param response      [Response]
        # @param result_id_key [String]   e.g. "reservation_id", "order_id", "id"
        # @return [String, nil]
        # True when the refusal's own text names +key+ — the property this
        # scenario injected. A 400 that names something else is a different
        # validation failure and must NOT be read as the attack being caught.
        def refusal_names?(response, key)
          return false if key.nil? || key.to_s.empty?

          body = response.body
          return false unless body.is_a?(Hash)

          "#{body["detail"]} #{body["hint"]}".include?(key.to_s)
        end

        # An action answers its own object, VERBATIM (spec §8.2) — there is no
        # `value` wrapper to unwrap since the 0.4 cutover retired the envelope.
        # The `value` shape is still read, because "verbatim" means an operator
        # is free to render a `value` key of their own, and reading only the
        # bare shape would break such a provider for no reason; but the bare
        # object is what every shipped verb answers, and reading only the
        # WRAPPED one is why this returned nil on every real origin.
        def extract_id(response, result_id_key)
          body = response.body
          return nil unless body.is_a?(Hash)

          nested = body["value"]
          source = nested.is_a?(Hash) && nested.key?(result_id_key) ? nested : body

          v = source[result_id_key]
          v&.to_s&.empty? == false ? v : nil
        end
      end
    end
  end
end
