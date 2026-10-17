# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # A token whose claim was changed without re-signing must be refused 401.
      # The probe dials per_user_query: an unrouted verb answers 404 before any credential is read.
      class TokenTampering < Scenario
        def initialize
          super(
            name: 'TokenTampering',
            category: 'authentication',
            description: 'Altered JWT (claim flipped, signature unchanged) must be rejected 401',
          )
        end

        NO_ROUTED_VERB = 'this profile declares no `per_user_query`, so there is no verb this ' \
                         'origin is known to route — and a name it does not route answers a ' \
                         'routing 404 before the credential is read, which would score a block ' \
                         'the token check never made. Declare `per_user_query:` to run this beat.'

        def call(client, profile)
          verb = profile.per_user_query
          return Verdict.new(blocked: false, skipped: true, status: 0, detail: NO_ROUTED_VERB) if verb.nil?

          resp = client.query(tampered(client.register!), name: verb)
          # A broken signature is an authentication failure: 403 or 402 would mean it was accepted.
          verdict_from(resp, expect: 401, detail: "tampered token accepted (HTTP #{resp.status})")
        end

        private

        def tampered(principal)
          Kiosk::TestHelpers::Assistant::Principal.new(
            agent_id: principal.agent_id,
            user_id: principal.user_id,
            token: tamper_token(principal.token),
            rsa_key: principal.rsa_key
          )
        end
      end
    end
  end
end
