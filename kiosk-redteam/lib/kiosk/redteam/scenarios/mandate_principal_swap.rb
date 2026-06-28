# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Mandate principal-swap: B signs a cart mandate claiming A's identity.
      #
      # Attack:
      #   1. A and B register.
      #   2. A creates an owned resource.
      #   3. B calls profile.pay_for with A's mandate payloads (user_id /
      #      agent_id belonging to A) but submits the pay command under B's
      #      bearer token.  client.pay signs the payloads with B's RSA key.
      #   4. BLOCKED iff the provider rejects the pay (mandate principal must
      #      match the authenticated signer, or ownership must be A's).
      #
      # Skipped when: profile.pay_for or profile.create_owned is nil.
      class MandatePrincipalSwap < Scenario
        def initialize
          super(
            name:        "MandatePrincipalSwap",
            category:    "mandate",
            description: "B signs a mandate carrying A's identity; provider must reject",
          )
        end

        def call(client, profile)
          return skip_verdict("no pay_for")      unless profile.pay_for
          return skip_verdict("no create_owned") unless profile.create_owned

          a = register_principal(client, name: "redteam-mps-a", profile:)
          b = register_principal(client, name: "redteam-mps-b", profile:)

          owned_ref = profile.create_owned.call(client, a)

          # Obtain mandate payloads built with A's identity (user_id, agent_id).
          mandates = profile.pay_for.call(client, a, owned_ref)

          # Submit those A-identity payloads signed by B's key under B's token.
          # The server must detect the mismatch (claimed principal ≠ signer /
          # authenticated agent) and reject.
          resp = client.pay(b, intent: mandates[:intent], cart: mandates[:cart])

          verdict_from(resp, detail: "principal-swap mandate accepted (HTTP #{resp.status})")
        end
      end
    end
  end
end
