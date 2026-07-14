# frozen_string_literal: true

require "json"

module Kiosk
  module Server
    # Discovery generator — one model over {Kiosk::Configuration} + the
    # request's base URL, four renderers, no drift (0.2 standards alignment):
    #
    #   .build / .build_json          — the bespoke `/.well-known/kiosk.json`
    #                                   (a DERIVED ALIAS, byte-stable)
    #   .agents_txt                   — native agents.txt v1.0 envelope
    #   .agents_json / _string        — native agents.json v1.0 companion
    #   .agent_configuration          — /.well-known/agent-configuration
    #                                   (agent-auth discovery, kiosk-pop)
    #
    # Each renderer is a pure function — no Rails dependency, no I/O — so the
    # four discovery surfaces cannot drift from one another.
    #
    # See the Discovery section of the spec.
    module WellKnown
      # Schema version of the well-known document itself (separate from
      # the API version).
      DOCUMENT_VERSION = "1.0"

      # Version of the agents.txt / agents.json standard Kiosk targets.
      AGENTS_VERSION  = "1.0"
      AGENTS_STANDARD = "https://agents-txt.com/standard"

      # Build the well-known document as a Hash, ready to JSON-serialize.
      #
      # @param config [Kiosk::Configuration] active config (default
      #   `Kiosk.configuration`)
      # @param base_url [String] the provider's HTTPS origin
      #   (e.g. `https://acme.example`); MUST be the same-registrable-domain
      #   the well-known is served from.
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
            challenge_url: auth_urls(endpoint)[:challenge],
            register_url:  auth_urls(endpoint)[:register],
            login_url:     auth_urls(endpoint)[:login],
            revoke_url:    auth_urls(endpoint)[:revoke],
          },
          # Verb names the endpoint actually serves — subset of
          # schema/query/run/pay, computed from the live registry (ADR-0009).
          capabilities: Array(config.capabilities),
          min_client:   config.min_client,
          issuer:       config.issuer,
          owner:        config.owner,
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

      # ── W1: native agents.txt v1.0 envelope ────────────────────────────
      #
      # `text/plain; charset=utf-8` body advertising the Kiosk provider in the
      # agents.txt v1.0 directive vocabulary (agents-txt.com, 2025-10-13):
      # line-based, `#` comments, blank-line-separated blocks. The 402
      # payment/PoW detail stays OUT of this file (it lives in the 402 body).
      #
      # @return [String]
      def self.agents_txt(base_url:, config: Kiosk.configuration)
        validate_issuer!(config)
        base = base_url.to_s.chomp("/")

        lines = [
          "# agents.txt — https://agents-txt.com",
          "# JSON: #{base}/agents.json",
          "",
          "Protocols: ap2",
          "Payments: required",
          "",
          "Authorization: agent-auth",
          "Identity: required",
        ]
        if config.skill_url && !config.skill_url.to_s.empty?
          lines << ""
          lines << "Skills: #{config.skill_url}"
        end

        "#{lines.join("\n")}\n"
      end

      # ── W1: native agents.json v1.0 companion ──────────────────────────
      #
      # Structured companion at `<origin>/agents.json` (schema
      # agents-txt.com/schema/agents-json/v1.0.json). Required keys:
      # `version`, `standard`, `site{name,url}`. The Kiosk six-verb wire
      # contract rides the sanctioned `x-kiosk` experimental extension
      # (agents.json ignores unknown top-level keys), so it cannot force our
      # runtime shape into a standard field.
      #
      # @return [Hash]
      def self.agents_json(base_url:, config: Kiosk.configuration)
        validate_issuer!(config)
        base = base_url.to_s.chomp("/")

        doc = {
          version:  AGENTS_VERSION,
          standard: AGENTS_STANDARD,
          site:     { name: site_name(config), url: base },
          # AP2 = "Mandate-trust layer with VC presentations" (agents.json
          # v1.0). A Kiosk provider gates all access, so payment is required.
          payments: {
            ap2:      { description: "Mandate-trust layer with VC presentations" },
            required: true,
          },
          authorization: {
            protocols: ["agent-auth"],
            discovery: "/.well-known/agent-configuration",
            identity:  "required",
          },
          skills: skills_list(config),
          # Kiosk extension: the structured six-verb contract the envelope
          # points at. `x-` is the sanctioned experimental prefix.
          "x-kiosk": {
            wire:        { verbs: Array(config.capabilities),
                           schema: "#{config.mount_path}/schema" },
            min_client:  config.min_client,
            api_version: Kiosk::Protocol::API_VERSION,
            mount_path:  config.mount_path,
          },
        }

        doc
      end

      # JSON-encoded form of {#agents_json}.
      def self.agents_json_string(**kwargs)
        JSON.generate(agents_json(**kwargs))
      end

      # ── W3: /.well-known/agent-configuration (agent-auth discovery) ─────
      #
      # Publishes the kiosk-pop auth capability so `Authorization: agent-auth`
      # resolves: the challenge/register/login/revoke endpoints, the PoP mode,
      # and the JWKS pointer. RFC 8414-style JSON, rendered from the same
      # model as {#build}.
      #
      # @return [Hash]
      def self.agent_configuration(base_url:, config: Kiosk.configuration)
        validate_issuer!(config)
        base = base_url.to_s.chomp("/")
        endpoint = base + config.mount_path

        {
          issuer:     config.issuer,
          endpoints:  auth_urls(endpoint),
          jwks_uri:   "#{endpoint}/.well-known/jwks.json",
          auth_modes: ["kiosk-pop"],
        }
      end

      # Absolute URLs of the four kiosk-pop auth endpoints under `endpoint`
      # (= base_url + mount_path). DRY seam shared by {#build} (which reshapes
      # them into the kiosk.json `auth` block) and {#agent_configuration}.
      def self.auth_urls(endpoint)
        {
          challenge: "#{endpoint}/auth/challenge",
          register:  "#{endpoint}/auth/register",
          login:     "#{endpoint}/auth/login",
          revoke:    "#{endpoint}/auth/revoke",
        }
      end
      private_class_method :auth_urls

      # site.name for agents.json: the provider's owner name when set, else the
      # issuer host (a stable, always-present fallback).
      def self.site_name(config)
        name = config.owner.is_a?(Hash) ? config.owner[:name] : nil
        return name if name && !name.to_s.empty?

        host_of(config.issuer)
      end
      private_class_method :site_name

      def self.host_of(issuer)
        require "uri"
        URI.parse(issuer.to_s).host || issuer.to_s
      rescue URI::InvalidURIError
        issuer.to_s
      end
      private_class_method :host_of

      # skills[] for agents.json: one entry when a skill URL is configured,
      # else an empty array (unknown skill → advertise none).
      def self.skills_list(config)
        return [] if config.skill_url.nil? || config.skill_url.to_s.empty?

        [{ url: config.skill_url, description: "Kiosk wire skill" }]
      end
      private_class_method :skills_list

      def self.validate_issuer!(config)
        return if config.issuer && !config.issuer.to_s.empty?

        raise ArgumentError,
              "Kiosk.configuration.issuer must be set before serving " \
              "/.well-known/kiosk.json — the issuer " \
              "is the AP2 mandate `iss` anchor"
      end
    end
  end
end
