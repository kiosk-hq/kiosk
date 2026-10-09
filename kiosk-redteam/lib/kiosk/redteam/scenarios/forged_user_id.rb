# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B calls forge_action with A's user_id injected; the server must take the
      # principal from the token, so A must not see the new resource.
      class ForgedUserId < Scenario
        # The protocol's name for a principal everywhere it appears.
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

          a = client.register!
          b = client.register!

          base_args   = profile.forge_args.call(client, a, b)
          forged_args = base_args.merge(FORGED_ARG.to_sym => a.user_id)

          resp = client.run(b, name: profile.forge_action, **forged_args)

          stall = payment_required_stall(resp, step: "the forged-user_id #{profile.forge_action} call")
          return stall if stall

          # A 400 naming the injected property is the input schema refusing it (§8.1).
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

          if Kiosk::Redteam.blocked?(resp)
            return verdict_from(resp, expect: [401, 403], detail: "forge_action rejected")
          end

          # Without per_user_query ownership cannot be verified, so this cannot pass.
          unless profile.per_user_query
            return Verdict.new(
              blocked: false,
              skipped: false,
              status:  resp.status,
              detail:  "forge_action returned #{resp.status}; cannot verify ownership (no per_user_query)",
            )
          end

          new_id = extract_id(resp, profile.result_id_key)

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

        def refusal_names?(response, key)
          return false if key.nil? || key.to_s.empty?

          body = response.body
          return false unless body.is_a?(Hash)

          "#{body["detail"]} #{body["hint"]}".include?(key.to_s)
        end

        # An action answers its own object (§8.2); a `value` key of the operator's own is read too.
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
