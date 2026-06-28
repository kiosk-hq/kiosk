# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Mandate replay: B re-submits A's already-used cart mandate JWS.
      #
      # Attack:
      #   1. A and B register.
      #   2. A creates an owned resource and builds (but does not yet submit)
      #      mandate payloads, then signs them manually to capture the raw JWS.
      #   3. A submits the pay (consuming the mandate).
      #   4. B takes A's exact intent_jws + cart_jws and re-submits under B's
      #      bearer token.
      #   5. BLOCKED iff the provider rejects the replay (mandate binds to the
      #      authenticated signer; B's token + A's JWS must not be accepted).
      #
      # Skipped when: profile.pay_for or profile.create_owned is nil.
      class MandateReplay < Scenario
        def initialize
          super(
            name:        "MandateReplay",
            category:    "mandate",
            description: "B re-submits A's signed cart JWS; provider must reject",
          )
        end

        def call(client, profile)
          return skip_verdict("no pay_for")      unless profile.pay_for
          return skip_verdict("no create_owned") unless profile.create_owned

          a = register_principal(client, name: "redteam-mr-a", profile:)
          b = register_principal(client, name: "redteam-mr-b", profile:)

          owned_ref = profile.create_owned.call(client, a)
          mandates  = profile.pay_for.call(client, a, owned_ref)

          # Capture A's raw JWS before submitting.
          intent_jws = client.sign_mandate(a, mandates[:intent])
          cart_jws   = client.sign_mandate(a, mandates[:cart])

          # A pays legitimately (consuming the mandate).
          client.pay(a, intent: mandates[:intent], cart: mandates[:cart])

          # B re-submits A's exact JWS under B's token.
          resp = submit_raw_pay(client, b, intent_jws:, cart_jws:)

          verdict_from(resp, detail: "mandate replay accepted under B's token (HTTP #{resp.status})")
        end

        private

        # Post a pay command with pre-built JWS strings without re-signing.
        # Uses client's private post_json so we can inject arbitrary JWS.
        def submit_raw_pay(client, principal, intent_jws:, cart_jws:)
          client.__send__(:post_json,
            "/kiosk/exec",
            {
              command: "pay",
              body: {
                intent_mandate_jws: intent_jws,
                cart_mandate_jws:   cart_jws,
              },
            },
            bearer: principal.token,
          )
        end
      end
    end
  end
end
