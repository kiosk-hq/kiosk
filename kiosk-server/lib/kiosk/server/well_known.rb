# frozen_string_literal: true

require "json"

module Kiosk
  module Server
    # Builds the `/.well-known/kiosk.json` discovery document.
    # Pure function over {Kiosk::Configuration} and the request's base URL —
    # no Rails dependency, no I/O.
    #
    # See design spec §3.4 «Auto-discovery via /.well-known/kiosk.json».
    module WellKnown
      # Schema version of the well-known document itself (separate from
      # the API version).
      DOCUMENT_VERSION = "1.0"

      # Build the well-known document as a Hash, ready to JSON-serialize.
      #
      # @param config [Kiosk::Configuration] active config (default
      #   `Kiosk.configuration`)
      # @param base_url [String] the provider's HTTPS origin
      #   (e.g. `https://acme.example`); MUST be the same-registrable-domain
      #   the well-known is served from per §3.4
      # @return [Hash]
      def self.build(base_url:, config: Kiosk.configuration)
        validate_issuer!(config)

        base = base_url.to_s.chomp("/")
        endpoint = base + config.mount_path

        kiosk = {
          version:  DOCUMENT_VERSION,
          endpoint: endpoint,
          # Proof-of-possession challenge-response (NOT OAuth). The agent proves
          # it holds the private key for a per-domain keypair; see skill.md and
          # specification.html "Registration & login".
          auth: {
            kind:          "kiosk-pop",
            challenge_url: "#{endpoint}/auth/challenge",
            register_url:  "#{endpoint}/auth/register",
            login_url:     "#{endpoint}/auth/login",
            revoke_url:    "#{endpoint}/auth/revoke",
          },
          capabilities: Array(config.capabilities),
          min_client:   config.min_client,
          issuer:       config.issuer,
          owner:        config.owner || {},
        }
        if config.skill_sha256
          kiosk[:skill] = { url: config.skill_url, sha256: config.skill_sha256 }
        end

        { kiosk: kiosk }
      end

      # JSON-encoded form of {#build}. Suitable to return directly from a
      # Rack/Rails endpoint.
      def self.build_json(**kwargs)
        JSON.generate(build(**kwargs))
      end

      def self.validate_issuer!(config)
        return if config.issuer && !config.issuer.to_s.empty?

        raise ArgumentError,
              "Kiosk.configuration.issuer must be set before serving " \
              "/.well-known/kiosk.json — see design spec §3.4 (the issuer " \
              "is the AP2 mandate `iss` anchor)"
      end
    end
  end
end
