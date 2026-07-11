# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack,
# unit tests) by simply not loading this file when ActionController::API
# isn't around. Engine wires up the route when Rails is present.

if defined?(::ActionController::API)
  require "kiosk/server/jwks"
  require "kiosk/server/headers"

  module Kiosk
    module Server
      # GET <endpoint>/.well-known/jwks.json — publishes the JWKS that
      # verifiers (agents, audit consumers, the badge prover,
      # cross-server mandate validators) use to check JWT
      # signatures issued by this deployment.
      #
      # The JWKS contains only public-key parameters; private parameters
      # never leave the server's memory (enforced by {SigningKey#to_jwk}).
      #
      # Response shape per RFC 7517 §5:
      #
      #   {
      #     "keys": [
      #       { "kty": "RSA", "use": "sig", "alg": "RS256",
      #         "kid": "<thumbprint>", "n": "...", "e": "AQAB" }
      #     ]
      #   }
      class JwksController < ::ActionController::API
        # Long-lived cache is safe — the only thing that changes is the
        # signing key, and that's a deliberate operator action (rotation).
        # We leave HTTP caching off here; operators put a CDN in front if
        # they care.
        def show
          Kiosk::Server::Headers.add_to(response.headers)
          render json: Kiosk::Server::Jwks.build(keys: [Kiosk.configuration.signing_key])
        end
      end
    end
  end
end
