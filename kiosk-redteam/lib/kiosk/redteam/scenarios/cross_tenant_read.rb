# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B's per_user_query must answer 200 without A's row, and A's own query
      # must return it: without that control, an empty answer proves nothing.
      class CrossTenantRead < Scenario
        def initialize
          super(
            name: 'CrossTenantRead',
            category: 'authorization',
            description: "B's per-user query must not return rows owned by A",
          )
        end

        def call(client, profile)
          skip_unless(profile, per_user_query: 'no per_user_query', create_owned: 'no create_owned') ||
            attack(client, profile)
        end

        private

        def attack(client, profile)
          a = client.register!
          owned_id = profile.create_owned.call(client, a)[:id].to_s
          control_failure(client.query(a, name: profile.per_user_query), profile, owned_id) ||
            isolation_verdict(client.query(client.register!, name: profile.per_user_query), profile, owned_id)
        end

        def control_failure(control, profile, owned_id)
          return nil if control.status == 200 && rows_contain?(control, profile.row_id_key, owned_id)

          breach_verdict(
            control.status,
            "CONTROL FAILED: A's own #{profile.per_user_query} must answer 200 and list " \
            "A's own resource id=#{owned_id} under row_id_key=" \
            "#{profile.row_id_key.inspect} — got HTTP #{control.status} " \
            "#{control.body.inspect}. Until it does, B seeing nothing proves nothing."
          )
        end

        def isolation_verdict(resp, profile, owned_id)
          # An unanswered query is not isolation: an error envelope also reads as no rows.
          unless resp.status == 200
            return breach_verdict(resp.status,
                                  "B's #{profile.per_user_query} was not answered (HTTP #{resp.status}: " \
                                  "#{resp.body.inspect}); an unanswered query is not proof of isolation")
          end
          return blocked_verdict(resp.status) unless rows_contain?(resp, profile.row_id_key, owned_id)

          breach_verdict(resp.status, "A's resource id=#{owned_id} visible in B's #{profile.per_user_query} result")
        end

        def rows_contain?(response, row_id_key, owned_id)
          rows_from(response).any? { |row| row[row_id_key].to_s == owned_id }
        end
      end
    end
  end
end
