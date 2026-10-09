# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B's per_user_query must answer 200 without A's row, and A's own query
      # must return it: without that control, an empty answer proves nothing.
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

          a = client.register!
          owned_ref = profile.create_owned.call(client, a)
          owned_id  = owned_ref[:id].to_s

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

          b = client.register!
          resp = client.query(b, name: profile.per_user_query)

          # An unanswered query is not isolation: an error envelope also reads as no rows.
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
