# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Cross-tenant read isolation: principal B must not see rows owned by A.
      #
      # Attack:
      #   1. A registers and creates an owned resource (via profile.create_owned).
      #   2. B registers and queries profile.per_user_query.
      #   3. BLOCKED iff B's result rows do NOT include A's resource id.
      #   4. BREACH  iff B's result rows DO include A's resource id.
      #
      # Skipped when: profile.per_user_query or profile.create_owned is nil.
      class CrossTenantRead < Scenario
        def initialize
          super(
            name:        "CrossTenantRead",
            category:    "authorization",
            description: "B's per-user query must not return rows owned by A",
          )
        end

        def call(client, profile)
          return skip_verdict("no per_user_query") unless profile.per_user_query
          return skip_verdict("no create_owned")   unless profile.create_owned

          a = register_principal(client, name: "redteam-ctr-a", profile:)
          owned_ref = profile.create_owned.call(client, a)
          owned_id  = owned_ref[:id].to_s

          b = register_principal(client, name: "redteam-ctr-b", profile:)
          resp = client.query(b, name: profile.per_user_query)

          # A server-side block (4xx on the query itself) also counts.
          return verdict_from(resp, detail: "query rejected unexpectedly") if Kiosk::Redteam.blocked?(resp)

          leaked = rows_from(resp).any? do |row|
            row[profile.row_id_key].to_s == owned_id
          end

          if leaked
            Verdict.new(
              blocked: false,
              skipped: false,
              status:  resp.status,
              detail:  "A's resource id=#{owned_id} visible in B's #{profile.per_user_query} result",
            )
          else
            Verdict.new(blocked: true, skipped: false, status: resp.status, detail: "")
          end
        end
      end
    end
  end
end
