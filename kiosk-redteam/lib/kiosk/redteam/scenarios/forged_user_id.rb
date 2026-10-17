# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # B calls forge_action with A's user_id injected; the server must take the
      # principal from the token, so A must not see the new resource.
      class ForgedUserId < Scenario
        # The protocol's name for a principal everywhere it appears.
        FORGED_ARG = 'user_id'

        def initialize
          super(
            name: 'ForgedUserId',
            category: 'authorization',
            description: 'An agent-supplied user_id must never decide ownership: the server ' \
                         'either refuses the argument outright or ignores it and takes the ' \
                         'principal from the access token',
          )
        end

        def call(client, profile)
          skip_unless(profile, forge_action: 'no forge_action', forge_args: 'no forge_args') ||
            attack(client, profile)
        end

        private

        def attack(client, profile)
          a = client.register!
          b = client.register!
          forged_args = profile.forge_args.call(client, a, b).merge(FORGED_ARG.to_sym => a.user_id)
          resp = client.run(b, name: profile.forge_action, **forged_args)
          refusal_verdict(resp, profile) || ownership_verdict(client, a, resp, profile)
        end

        # The verdict when the origin refused the forged call, else nil.
        def refusal_verdict(resp, profile)
          stall = payment_required_stall(resp, step: "the forged-user_id #{profile.forge_action} call")
          return stall if stall
          return contract_refusal(resp) if contract_refusal?(resp)
          return verdict_from(resp, expect: [401, 403], detail: 'forge_action rejected') if Kiosk::Redteam.blocked?(resp)

          nil
        end

        # A 400 naming the injected property is the input schema refusing it (§8.1).
        def contract_refusal?(resp)
          resp.status == 400 && Kiosk::Redteam.error_code(resp) == 'bad_request' &&
            refusal_names?(resp, FORGED_ARG)
        end

        def contract_refusal(resp)
          blocked_verdict(resp.status,
                          'forge_action refused by the declared input contract: 400 bad_request naming ' \
                          "#{FORGED_ARG.inspect} — the principal is not an accepted argument")
        end

        def ownership_verdict(client, owner, resp, profile)
          # Without per_user_query ownership cannot be verified, so this cannot pass.
          unless profile.per_user_query
            return breach_verdict(resp.status,
                                  "forge_action returned #{resp.status}; cannot verify ownership (no per_user_query)")
          end

          new_id = extract_id(resp, profile.result_id_key)
          return leak_verdict(client, owner, resp, profile, new_id) if new_id

          breach_verdict(resp.status,
                         "forge_action returned #{resp.status} but result_id_key=#{profile.result_id_key.inspect} " \
                         'not found in response; cannot confirm ownership was enforced')
        end

        def leak_verdict(client, owner, resp, profile, new_id)
          rows = rows_from(client.query(owner, name: profile.per_user_query))
          return blocked_verdict(resp.status) if rows.none? { |r| r[profile.row_id_key].to_s == new_id.to_s }

          breach_verdict(resp.status,
                         "forged user_id=#{owner.user_id} was honoured; resource id=#{new_id} visible in A's rows")
        end

        def refusal_names?(response, key)
          return false if key.nil? || key.to_s.empty?

          body = response.body
          return false unless body.is_a?(Hash)

          "#{body['detail']} #{body['hint']}".include?(key.to_s)
        end

        # An action answers its own object (§8.2); a `value` key of the operator's own is read too.
        def extract_id(response, result_id_key)
          body = response.body
          return nil unless body.is_a?(Hash)

          nested = body['value']
          source = nested.is_a?(Hash) && nested.key?(result_id_key) ? nested : body

          v = source[result_id_key]
          v&.to_s&.empty? == false ? v : nil
        end
      end
    end
  end
end
