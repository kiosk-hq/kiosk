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
        def initialize
          super(
            name:        "ForgedUserId",
            category:    "authorization",
            description: "Agent-supplied user_id in run args must be ignored by the server",
          )
        end

        def call(client, profile)
          return skip_verdict("no forge_action") unless profile.forge_action
          return skip_verdict("no forge_args")   unless profile.forge_args

          a = register_principal(client, name: "redteam-fui-a", profile:)
          b = register_principal(client, name: "redteam-fui-b", profile:)

          base_args   = profile.forge_args.call(client, a, b)
          forged_args = base_args.merge(user_id: a.user_id)

          resp = client.run(b, name: profile.forge_action, **forged_args)

          # A 402 answered nothing: a toll fires ahead of the handler, and a
          # payment_setup_required means B never had a card. Neither says
          # whether the injected user_id would have been honoured, and the
          # ownership check below cannot run either — there is no new resource
          # to look for. Say could-not-test rather than reading the rest of this
          # method's silence as a pass (K-736).
          stall = payment_required_stall(resp, step: "the forged-user_id #{profile.forge_action} call")
          return stall if stall

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
        def extract_id(response, result_id_key)
          body = response.body
          return nil unless body.is_a?(Hash)

          value = body["value"]
          return nil unless value.is_a?(Hash)

          v = value[result_id_key]
          v&.to_s&.empty? == false ? v : nil
        end
      end
    end
  end
end
