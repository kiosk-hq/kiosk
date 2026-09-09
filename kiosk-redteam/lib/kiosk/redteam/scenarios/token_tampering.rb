# frozen_string_literal: true

module Kiosk
  module Redteam
    module Scenarios
      # Token tampering: alter a JWT claim without re-signing.
      #
      # Attack:
      #   1. B registers and receives a valid bearer token (RS256 JWT issued by
      #      the provider).
      #   2. The scenario decodes the token's payload segment, flips a claim
      #      (role, sub, or exp), and re-encodes — keeping the original
      #      signature.  The signature no longer matches the new payload.
      #   3. Any API call made with the tampered token must be rejected 401.
      #
      # BLOCKED iff the tampered-token call returns 401 (or another blocked
      # status / domain error code).
      #
      # THE PROBE MUST DIAL A VERB THIS ORIGIN ACTUALLY ROUTES. An origin draws
      # one explicit route per registered verb and nothing else, so a made-up
      # name matches no route at all: the answer is the web framework's own 404,
      # decided before any credential is read, which would read as "the tampered
      # token was refused" while proving nothing whatever about the token. The
      # profile's `per_user_query` is its declaration of a verb this origin
      # really serves, and a profile that declares none cannot run this beat.
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

          b = register_principal(client, name: "redteam-tt-b", profile:)

          tampered = tamper_token(b.token)

          # Use the tampered token to call any endpoint (query or a dummy run).
          # We craft a minimal principal that carries the tampered bearer token
          # but still has a valid RSA key (so sign_mandate would work if called).
          tampered_principal = Principal.new(
            agent_id: b.agent_id,
            user_id:  b.user_id,
            token:    tampered,
            rsa_key:  b.rsa_key,
          )

          # Try to query — any ROUTED verb will exercise the auth middleware.
          resp = client.query(tampered_principal, name: verb)

          # 401 and nothing else. A signature that no longer matches its payload
          # is an AUTHENTICATION failure — the request has no identity — so a
          # 403 would mean the token was accepted and then authorized against,
          # and a 402 would mean a toll fired ahead of the signature check.
          # NEITHER counts as blocked. The problem `code` is deliberately not
          # pinned: a 401 raised in auth middleware may be rendered before the
          # problem document is built.
          verdict_from(resp, expect: 401, detail: "tampered token accepted (HTTP #{resp.status})")
        end
      end
    end
  end
end
