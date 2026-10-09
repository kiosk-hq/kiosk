# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # A token whose claim was changed without re-signing must be refused 401.
      # The probe dials per_user_query: an unrouted verb answers 404 before any credential is read.
      class TokenTampering < Scenario
        def initialize
          super(
            name:        "TokenTampering",
            category:    "authentication",
            description: "Altered JWT (claim flipped, signature unchanged) must be rejected 401",
          )
        end

        def call(client, profile)
          verb = profile.per_user_query
          if verb.nil?
            return Verdict.new(
              blocked: false, skipped: true, status: 0,
              detail:  "this profile declares no `per_user_query`, so there is no verb this " \
                       "origin is known to route — and a name it does not route answers a " \
                       "routing 404 before the credential is read, which would score a block " \
                       "the token check never made. Declare `per_user_query:` to run this beat.",
            )
          end

          b = client.register!

          tampered = tamper_token(b.token)

          tampered_principal = Kiosk::TestHelpers::Assistant::Principal.new(
            agent_id: b.agent_id,
            user_id:  b.user_id,
            token:    tampered,
            rsa_key:  b.rsa_key,
          )

          resp = client.query(tampered_principal, name: verb)

          # A broken signature is an authentication failure: 403 or 402 would mean it was accepted.
          verdict_from(resp, expect: 401, detail: "tampered token accepted (HTTP #{resp.status})")
        end
      end
    end
  end
end
