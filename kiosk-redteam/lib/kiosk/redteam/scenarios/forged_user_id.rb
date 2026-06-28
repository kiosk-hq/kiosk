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

          # If the call was rejected outright, the server caught it.
          return verdict_from(resp, detail: "forge_action rejected") if Kiosk::Redteam.blocked?(resp)

          # Call succeeded — check whether A's per_user_query now contains the
          # resource.  If per_user_query is unavailable, we cannot verify
          # ownership and must treat a 200 as a breach (conservative).
          unless profile.per_user_query
            return Verdict.new(
              blocked: false,
              status:  resp.status,
              detail:  "forge_action returned #{resp.status}; cannot verify ownership (no per_user_query)",
            )
          end

          # Extract the new resource id from the action response.
          new_id = extract_id(resp, profile.row_id_key)

          query_resp = client.query(a, name: profile.per_user_query)
          a_rows     = rows_from(query_resp)
          leaked     = new_id && a_rows.any? { |r| r[profile.row_id_key].to_s == new_id.to_s }

          if leaked
            Verdict.new(
              blocked: false,
              status:  resp.status,
              detail:  "forged user_id=#{a.user_id} was honoured; resource visible in A's rows",
            )
          else
            Verdict.new(blocked: true, status: resp.status, detail: "")
          end
        end

        private

        # Try to extract the resource id from the action response body.
        # Looks for common key patterns; returns nil when not found.
        def extract_id(response, row_id_key)
          body = response.body
          return nil unless body.is_a?(Hash)

          value = body["value"]
          return nil unless value.is_a?(Hash)

          value[row_id_key] || value["id"] || value["reservation_id"] || value["order_id"]
        end
      end
    end
  end
end
