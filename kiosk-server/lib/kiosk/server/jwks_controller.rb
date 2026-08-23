# frozen_string_literal: true

# Engine wires up the route.

require "action_controller"
require "kiosk/server/jwks"
require "kiosk/server/headers"

module Kiosk
  module Server
    # GET <endpoint>/.well-known/jwks.json — publishes the JWKS that
    # verifiers (agents, audit consumers, cross-server mandate
    # validators) use to check JWT signatures issued by this deployment.
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
      # ONE key, always (K-933): there is no configuration that adds a second,
      # so the rotation overlap window {Jwks} describes cannot be opened from
      # here. `ROADMAP.md` ("Key rotation") carries the gap.
      def show
        Kiosk::Server::Headers.add_to(response.headers)
        render json: Kiosk::Server::Jwks.build(keys: [Kiosk.configuration.signing_key])
      end
    end
  end
end
