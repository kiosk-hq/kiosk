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
      class TokenTampering < Scenario
        def initialize
          super(
            name:        "TokenTampering",
            category:    "authentication",
            description: "Altered JWT (claim flipped, signature unchanged) must be rejected 401",
          )
        end

        def call(client, profile)
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

          # Try to query — any verb will exercise the auth middleware.
          resp = client.query(tampered_principal, name: "ping")

          # 401 and nothing else. A signature that no longer matches its payload
          # is an AUTHENTICATION failure — the request has no identity — so a
          # 403 would mean the token was accepted and then authorized against,
          # and a 402 would mean a toll fired ahead of the signature check.
          # Both used to score BLOCKED. The `error.code` is deliberately not
          # pinned: a 401 raised in auth middleware may be rendered before the
          # error envelope is built.
          verdict_from(resp, expect: 401, detail: "tampered token accepted (HTTP #{resp.status})")
        end
      end
    end
  end
end
