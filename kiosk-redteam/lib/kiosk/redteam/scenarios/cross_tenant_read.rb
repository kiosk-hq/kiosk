# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Cross-tenant read isolation: principal B must not see rows owned by A.
      #
      # Attack:
      #   1. A registers and creates an owned resource (via profile.create_owned).
      #   2. CONTROL — A's OWN per_user_query must answer 200 and contain A's
      #      row under profile.row_id_key.
      #   3. B registers and queries profile.per_user_query; the query must be
      #      ANSWERED (HTTP 200).
      #   4. BLOCKED iff B's answered rows do NOT include A's resource id.
      #   5. BREACH  iff B's rows DO include it, iff B's query is not answered,
      #      or iff the control leg does not hold.
      #
      # The control is not decoration (K-729). "B's rows do not contain A's id"
      # is satisfied by every way of returning nothing: a provider with no
      # isolation logic whose query happens to answer `[]`, a `row_id_key` that
      # names no field in the rows (under which a REAL leak reads as clean), a
      # 404 from a query name that was never registered, a 402 toll, a 500. The
      # control pins the one reading that makes the absence meaningful — this
      # query DOES return this key for its owner — and step 3 refuses to score
      # an unanswered query as isolation.
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

          # ── CONTROL: the probe below can see a row when there is one to see ──
          control = client.query(a, name: profile.per_user_query)
          unless control.status == 200 && rows_contain?(control, profile.row_id_key, owned_id)
            return Verdict.new(
              blocked: false,
              skipped: false,
              status:  control.status,
              detail:  "CONTROL FAILED: A's own #{profile.per_user_query} must answer 200 and list " \
                       "A's own resource id=#{owned_id} under row_id_key=" \
                       "#{profile.row_id_key.inspect} — got HTTP #{control.status} " \
                       "#{control.body.inspect}. Until it does, B seeing nothing proves nothing.",
            )
          end

          b = register_principal(client, name: "redteam-ctr-b", profile:)
          resp = client.query(b, name: profile.per_user_query)

          # B's query must be ANSWERED and merely not contain A's row. A non-2xx
          # is not isolation: a 404 means the query name never resolved, a 402
          # means a toll fired before any policy ran, a 5xx is a crash — and the
          # gem's own invariant is that a crash can never count as a block
          # (see Kiosk::Redteam.blocked?). Each of the three used to score
          # BLOCKED here, because the empty `rows_from` of an error envelope is
          # indistinguishable from a correctly isolated empty result.
          unless resp.status == 200
            return Verdict.new(
              blocked: false,
              skipped: false,
              status:  resp.status,
              detail:  "B's #{profile.per_user_query} was not answered (HTTP #{resp.status}: " \
                       "#{resp.body.inspect}); an unanswered query is not proof of isolation",
            )
          end

          if rows_contain?(resp, profile.row_id_key, owned_id)
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

        private

        def rows_contain?(response, row_id_key, owned_id)
          rows_from(response).any? { |row| row[row_id_key].to_s == owned_id }
        end
      end
    end
  end
end
