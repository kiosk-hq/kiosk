# frozen_string_literal: true

module Kiosk
  module Server
    # Pure-Ruby JWKS document builder per RFC 7517 §5.
    #
    # The document at `<endpoint>/.well-known/jwks.json` lets
    # any verifier — agents, audit consumers, the badge prover,
    # cross-server mandate validators — fetch the public keys that
    # sign this deployment's JWTs.
    #
    # Multi-key shape supports key rotation: the deployment publishes both
    # the outgoing and incoming key for the overlap window, and verifiers
    # match against `kid` (which is the RFC 7638 thumbprint computed by
    # {SigningKey#kid}).
    #
    # @example Single-key document
    #   key = Kiosk::Server::SigningKey.generate
    #   Kiosk::Server::Jwks.build(keys: [key])
    #   # => { keys: [{ kty: "RSA", use: "sig", alg: "RS256",
    #   #              kid: "...", n: "...", e: "..." }] }
    module Jwks
      module_function

      # Build a JWKS document.
      #
      # @param keys [Array<SigningKey>] one or more signing keys; the first
      #   is the active signer, additional entries are kept for verifier
      #   overlap during rotation.
      # @return [Hash] JSON-ready hash with a single `keys:` field.
      def build(keys:)
        { keys: Array(keys).map(&:to_jwk) }
      end
    end
  end
end
