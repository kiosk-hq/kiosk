# frozen_string_literal: true

require "json"

module Kiosk
  module Server
    # Discovery generator — one model over {Kiosk::Configuration} + the
    # request's base URL, six renderers, no drift (0.2 standards alignment):
    #
    #   .build / .build_json          — the bespoke `/.well-known/kiosk.json`
    #                                   (a DERIVED ALIAS, byte-stable)
    #   .agents_txt                   — native agents.txt v1.0 envelope
    #   .agents_json                  — native agents.json v1.0 companion
    #   .agent_configuration          — /.well-known/agent-configuration
    #                                   (agent-auth discovery, kiosk-pop)
    #   .api_catalog                  — /.well-known/api-catalog
    #                                   (RFC 9727 linkset of the wire endpoints)
    #   .auth_md                      — /auth.md (agent-auth methods in the
    #                                   auth.md vocabulary)
    #
    # Each renderer is a pure function — no Rails dependency, no I/O — so the
    # six discovery surfaces cannot drift from one another.
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
            # Account-binding ceremony — additive 0.1.x-compatible
            # keys: the claim flow's opening endpoint and the link-code
            # redeem endpoint. Full ceremony description: <base>/auth.md.
            device_authorization_url: "#{endpoint}/oauth/device_authorization",
            claim_url:                "#{endpoint}/auth/claim",
          },
          # Verb names the endpoint actually serves — subset of
          # schema/query/run/pay, computed from the live registry.
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
        ]
        # Payment directives are emitted ONLY when the provider serves `pay`.
        # `capabilities` is the canonical computed set — `pay` drops
        # out when no payment provider is configured, so a
        # payment-less provider advertises no AP2/Payments here.
        if pay_served?(config)
          lines << ""
          lines << "Protocols: ap2"
          lines << "Payments: required"
        end
        lines << ""
        lines << "Authorization: agent-auth auth-md"
        lines << "Identity: required"
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
        }
        # `payments` is OPTIONAL in agents.json v1.0. Emit it ONLY when the
        # provider serves `pay`: `pay` drops out of `capabilities`
        # when no payment provider is configured, so a payment-less
        # provider advertises no AP2/payments block here.
        if pay_served?(config)
          # AP2 = "Mandate-trust layer with VC presentations" (agents.json v1.0).
          doc[:payments] = {
            ap2:      { description: "Mandate-trust layer with VC presentations" },
            required: true,
          }
        end
        doc[:authorization] = {
          protocols: ["agent-auth", "auth-md"],
          discovery: "/.well-known/agent-configuration",
          identity:  "required",
        }
        doc[:skills] = skills_list(config)
        # Kiosk extension: the structured six-verb contract the envelope
        # points at. `x-` is the sanctioned experimental prefix.
        doc[:"x-kiosk"] = {
          wire:        { verbs: Array(config.capabilities),
                         schema: "#{config.mount_path}/schema" },
          min_client:  config.min_client,
          api_version: Kiosk::Protocol::API_VERSION,
          mount_path:  config.mount_path,
          # RFC 9727 API Catalog pointer (root-served linkset). Lives under
          # the experimental `x-kiosk` namespace — agents.json v1.0 has no
          # standard link-catalog key, so we do NOT force a top-level field.
          api_catalog: "/.well-known/api-catalog",
        }

        doc
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
          # kiosk-pop = the anonymous-class + PoP self-registration story;
          # user-claimed = the agent-initiated claim ceremony; link-code =
          # the human-initiated link flow (Kiosk extension).
          auth_modes: ["kiosk-pop", "user-claimed", "link-code"],
          auth_md:    "#{base}/auth.md",
        }
      end

      # ── W-catalog: /.well-known/api-catalog (RFC 9727 linkset) ─────────
      #
      # RFC 9727 "API Catalog" served as an `application/linkset+json` body: a
      # single linkset member, `anchor`ed at the api-catalog URL, whose `item`
      # array hyperlinks the live API endpoints. Kiosk's "APIs" are the wire
      # verbs — `<endpoint>/{schema,query,run,pay}` — filtered to the verbs the
      # deployment actually serves (`config.capabilities`, computed from the
      # live registry), plus the agents.json discovery companion.
      #
      # The `schema` endpoint is the machine-readable surface description, so it
      # carries the RFC 9727 `service-desc` relation (SHOULD); so does the
      # DERIVED `openapi.json` beside it ({OpenApi}), which describes the same
      # verbs in a form generic OpenAPI tooling can consume. Every other link is
      # a plain `item`.
      #
      # @return [Hash]
      def self.api_catalog(base_url:, config: Kiosk.configuration)
        validate_issuer!(config)
        base = base_url.to_s.chomp("/")
        endpoint = base + config.mount_path
        verbs = Array(config.capabilities)

        items = []
        # schema is the machine-readable service description (service-desc).
        if verbs.include?("schema")
          items << { href: "#{endpoint}/schema", rel: "service-desc" }
          # ONE LINE, AND IT IS THE WHOLE ADVERTISEMENT of the derived OpenAPI
          # document (T-071 = C). RFC 8631 allows more than one `service-desc`,
          # and there genuinely are two descriptions of one API here: `schema`
          # is CANONICAL and is what the skill teaches an assistant to read;
          # `openapi.json` is the derived one a code generator, a mock server or
          # a request validator can consume. The bespoke one stays first.
          #
          # Gated on the same condition, because it derives from the same
          # registry: an origin with nothing registered has nothing to describe
          # either way. This is deliberately the ONLY place the document is
          # advertised anywhere — the skill names it nowhere, so no assistant
          # pays cold-start context for it. Deleting the provisional renderer
          # deletes this one `items <<`.
          items << { href: "#{endpoint}/openapi.json", rel: "service-desc" }
        end
        # The remaining wire verbs are plain catalogued APIs.
        %w[query run pay].each do |verb|
          items << { href: "#{endpoint}/#{verb}", rel: "item" } if verbs.include?(verb)
        end
        # The agents.json discovery companion (root-served).
        items << { href: "#{base}/agents.json", rel: "item" }

        {
          linkset: [
            { anchor: "#{base}/.well-known/api-catalog", item: items },
          ],
        }
      end

      # ── W5: /auth.md (agent-auth methods in the auth.md vocabulary) ────
      #
      # Markdown body served at `<origin>/auth.md`, following auth.md's
      # canonical section order (Title → Discover → Pick a method → Register
      # → Claim ceremony → Exchange → Use the access_token → Errors →
      # Revocation) and describing OUR methods honestly:
      #
      #   - in auth.md's taxonomy kiosk-pop is the ANONYMOUS class plus a
      #     proof-of-possession upgrade (auth.md has no PoP — that is
      #     Kiosk's "more"). It is NOT "Agent Verified": no external
      #     agent-IdP vouches for the agent.
      #   - `user_claimed` = the claim ceremony (RFC 8628 wire).
      #   - the link flow is labeled a Kiosk extension (auth.md defines no
      #     human-initiated direction).
      #   - `identity_assertion` (ID-JAG) — not supported, planned
      #     (the `issue()` seam).
      #
      # Rendered from the same model as the other five surfaces, so it
      # cannot drift; a change in the young auth.md format is one renderer
      # edit.
      #
      # @return [String]
      def self.auth_md(base_url:, config: Kiosk.configuration)
        validate_issuer!(config)
        base = base_url.to_s.chomp("/")
        endpoint = base + config.mount_path
        urls = auth_urls(endpoint)

        <<~MARKDOWN
          # #{site_name(config)} — agent authentication

          How AI assistants authenticate against this provider's Kiosk
          endpoint (`#{endpoint}`). Wire contract: the Kiosk specification
          (https://kiosk.tech/specification.html).

          ## Discover

          - This file: `#{base}/auth.md`
          - Agent auth configuration: `#{base}/.well-known/agent-configuration`
          - Kiosk discovery document: `#{base}/.well-known/kiosk.json`
          - Token-verification keys (JWKS): `#{endpoint}/.well-known/jwks.json`

          ## Pick a method

          - **Anonymous + proof-of-possession (kiosk-pop)** — supported.
            Self-registration of a per-provider RSA keypair: no human
            account needed. In auth.md terms this is the anonymous class,
            upgraded with a key-possession proof on every register/login.
          - **User claimed** — supported. The claim ceremony below binds an
            agent key to an EXISTING account after its holder approves in
            their own browser session.
          - **Link code** — supported (Kiosk extension: auth.md defines no
            human-initiated direction). The account holder mints a
            single-use code on the provider's site and hands it to the
            assistant.
          - **Identity assertion (ID-JAG)** — not supported (planned).

          ## Register

          kiosk-pop self-registration (anonymous class):

          1. `GET #{urls[:challenge]}?public_key=<PEM>` → `{ challenge, exp }`
          2. Sign a compact RS256 JWS over `{aud, nonce, jti}` with the
             private key (`aud` = the origin you dialed; `nonce` = the
             challenge).
          3. `POST #{urls[:register]}` `{ public_key, signed }`
             → `201 { agent_id, user_id, access_token }`

          Registration may be priced with an Equihash proof-of-work. When it
          is, step 3 answers `402 pow_required` with
          `WWW-Authenticate: Kiosk-PoW realm="<issuer>"` and the body carries
          the `challenges` array; the toll binds to the public key you are
          registering. Solve EVERY challenge and resubmit the SAME body — the
          possession proof is NOT consumed by the 402, so reuse the same
          `signed` — carrying the proof(s) in a `Kiosk-PoW` REQUEST HEADER as
          raw minified JSON (no base64):

              Kiosk-PoW: {"challenge":{…},"nonce":{"indices":[…],"header_nonce":0}}

          Send N proofs as a JSON array in that one header, or as one repeated
          `Kiosk-PoW` header line per proof. The proof NEVER travels in the
          request body: a body `pow` field is ignored, and changing the body
          invalidates the proofs. The same header answers a `402 pow_required`
          on the wire verbs too — there is no verb exemption, including the
          `schema` GET.

          ## Claim ceremony

          User-claimed binding (RFC 8628 wire) — binds YOUR key to the
          account holder's existing account; single-use, short-TTL codes:

          1. `POST #{endpoint}/oauth/device_authorization`
             (form-encoded: `client_id`, `public_key` — required) →
             `{ device_code, user_code, verification_uri, expires_in, interval }`
          2. Show the holder: "open <verification_uri>, enter <user_code>".
             They approve in their own signed-in browser session.
          3. Poll `POST #{endpoint}/oauth/token` (form-encoded:
             `grant_type=urn:ietf:params:oauth:grant-type:device_code`,
             `device_code`, and `signed` — the same challenge-response
             possession proof as register/login, for the SAME key from
             step 1) → `{ access_token, token_type, expires_in }`.
             No binding happens without a valid possession proof.

          Link flow (Kiosk extension, mirror direction): the holder mints a
          code on the provider's site and pastes it to you; redeem with
          `POST #{endpoint}/auth/claim` `{ code, public_key, signed }`
          → `201 { agent_id, user_id, access_token }`.

          A fresh key becomes a linked assistant account under the holder's
          account; an already-registered key is re-bound (its reputation
          carries over — claiming never resets an identity).

          ## Exchange

          There is no separate exchange step: registration, the claim
          ceremony and the link redeem each return the access token
          directly. Refresh by logging in with your key —
          `POST #{urls[:login]}` `{ public_key, signed }` — the ceremony
          never repeats.

          ## Use the access_token

          Send `Authorization: Bearer <access_token>` to the wire verbs
          under `#{endpoint}` (`schema`, `query`, `run`, `pay`). Tokens are
          RS256 JWTs verifiable against the JWKS above.

          ## Errors

          - Kiosk endpoints (`/auth/*`, wire verbs) use the JSON envelope:
            `{ ok: false, error: { code, message, hint } }` (codes such as
            `unauthenticated`, `not_found`, `conflict`, `pow_required`).
          - The claim ceremony's OAuth endpoints use the OAuth error shape
            `{ error, error_description }` with the RFC 8628 vocabulary:
            `authorization_pending`, `slow_down`, `expired_token`,
            `access_denied`, `invalid_grant`, `invalid_client` — a
            documented exception to the envelope.

          ## Revocation

          - Credential layer: `POST #{urls[:revoke]}` (Bearer) revokes every
            outstanding token for your identity and returns a fresh one.
          - Registration layer (unlink): the account holder — or the
            provider — deactivates a key's binding (`POST
            #{endpoint}/auth/unlink`, session-authenticated, or the
            provider's linked-assistants page). An unlinked key stops
            verifying and can no longer log in; it does NOT revert to a
            standalone account.
        MARKDOWN
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

      # Whether this deployment serves the `pay` verb — the canonical gate for
      # advertising AP2/payments across the discovery surfaces.
      # `capabilities` is the computed set; `pay` drops out when no
      # payment provider is configured, so this is false for payment-less
      # providers.
      def self.pay_served?(config)
        Array(config.capabilities).map(&:to_s).include?("pay")
      end
      private_class_method :pay_served?

      # site.name for agents.json: the provider's owner name when set, else the
      # issuer host (a stable, always-present fallback).
      #
      # PUBLIC because {OpenApi} titles the derived document with it. Naming
      # the origin is a model question, not a per-renderer one — a second
      # implementation of "what is this provider called" is precisely the drift
      # this module's one-model/many-renderers shape exists to prevent.
      def self.site_name(config)
        name = config.owner.is_a?(Hash) ? config.owner[:name] : nil
        return name if name && !name.to_s.empty?

        host_of(config.issuer)
      end

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
