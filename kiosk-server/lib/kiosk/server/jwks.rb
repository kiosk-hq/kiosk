# frozen_string_literal: true

module Kiosk
  module Server
    # Pure-Ruby JWKS document builder per RFC 7517 §5.
    #
    # The document at `<endpoint>/.well-known/jwks.json` lets
    # any verifier — agents, audit consumers, cross-server mandate
    # validators — fetch the public keys that sign this deployment's JWTs.
    #
    # RFC 7517 makes the document a LIST, and verifiers match against `kid`
    # (the RFC 7638 thumbprint computed by {SigningKey#kid}) — so the wire
    # format has room for the outgoing and the incoming key at once, which is
    # what an operator would need to roll a key without a break.
    #
    # THE SHIPPED DEPLOYMENT PUBLISHES EXACTLY ONE KEY, and this comment used
    # to describe the overlap window as if it existed (K-933).
    # {JwksController#show} renders `build(keys: [Kiosk.configuration.signing_key])`
    # and no configuration can add a second, so there is no window to publish
    # into: every verifier holding the outgoing `kid` fails the moment the key
    # changes. Opening it needs a configuration seam and a rotation ceremony —
    # `ROADMAP.md` ("Key rotation") states the gap in the same terms. Until
    # then `keys:` takes a list because the format does, not because the engine
    # ever passes more than one.
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
      # @param keys [Array<SigningKey>] the keys to publish, in order; the
      #   first is the active signer. The engine always passes exactly one
      #   (see the class note and `ROADMAP.md`); a caller assembling its own
      #   document may pass more.
      # @return [Hash] JSON-ready hash with a single `keys:` field.
      def build(keys:)
        { keys: Array(keys).map(&:to_jwk) }
      end
    end
  end
end
