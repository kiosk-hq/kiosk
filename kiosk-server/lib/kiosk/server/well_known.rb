# frozen_string_literal: true

require "json"
require "kiosk/server/actions"
require "kiosk/server/queries"
require "kiosk/server/schema_document"

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

      # Module name → the endpoint that module answers on, under `endpoint`,
      # for the modules the RFC 9727 catalog links as plain `item`s. `schema`
      # is absent because it is linked as a `service-desc` instead.
      #
      # `queries` and `actions` LEFT this table at the 0.4 cutover, with the
      # two multiplexed endpoints they mapped to (T-074 = A), and they do not
      # come back: a module that holds N verbs has N endpoints, so the catalog
      # links THE VERBS (see {api_catalog}, T-093) rather than inventing a
      # module-level URL that answers nothing. `pay` stays because it really is
      # one fixed endpoint.
      MODULE_ENDPOINTS = { "pay" => "pay" }.freeze

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
          # The MODULES this origin serves — subset of
          # schema/queries/actions/pay, computed from the live registry
          # (T-075 = A, ADR-0025). Not the registered verb NAMES, and since
          # T-094 that is a MODELLING statement rather than a security one: the
          # catalog is public now, so the names are one hop away at
          # `schema_url` below. What the module set buys is what an assistant
          # can act on BEFORE it fetches anything — which branches of its own
          # instructions apply: is there a catalog at all, are there writes,
          # can this origin take money.
          #
          # It is also the ONE place the module set is published. `schema`'s
          # descriptor carried a byte-identical copy under `verbs` until T-095;
          # it was the same `Array(config.capabilities)` call, so it was one
          # value with two names rather than two facts.
          capabilities: Array(config.capabilities),
          # THE CACHE-BUSTED LINK TO THE CATALOG (T-094). The digest is
          # {SchemaDocument}'s, derived at boot from the registry + this config
          # + the gem version, so it moves on any deploy that changes what
          # `schema` answers. That is what lets the catalog be cached for a
          # YEAR at this URL while THIS document — short-lived, and the only
          # thing a client must re-read — publishes the new link. The bare
          # `<endpoint>/schema` stays served and stays documented; it just
          # cannot be cached for long, because its bytes change under a fixed
          # URL.
          schema_url:   "#{endpoint}/schema?v=#{SchemaDocument.digest(config: config)}",
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
      # `version`, `standard`, `site{name,url}`. The Kiosk wire POINTERS ride
      # the sanctioned `x-kiosk` experimental extension (agents.json ignores
      # unknown top-level keys), so it cannot force our runtime shape into a
      # standard field.
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
        # Kiosk extension: WHERE to read the contract, not a copy of it
        # (T-075 = A, ADR-0025). `x-` is the sanctioned experimental prefix.
        #
        # This block used to echo `capabilities` under `wire.verbs`. It stops:
        # a discovery envelope that restates the catalog is a second source of
        # truth for it, and `kiosk.json` is canonical for the module set. So
        # the block carries two POINTERS (the catalog and the RFC 9727
        # linkset) and the two facts a client needs before it can dial either
        # (where the wire is mounted, which protocol series it speaks).
        # `min_client` went with `wire.verbs` for the same reason: it is
        # `kiosk.json`'s field.
        #
        # The `schema` pointer carries the same `?v=<digest>` cache-buster
        # `kiosk.json` publishes, for the same reason — a pointer that a
        # client may follow must point at the URL that is safe to cache.
        doc[:"x-kiosk"] = {
          schema:      "#{config.mount_path}/schema?v=#{SchemaDocument.digest(config: config)}",
          # RFC 9727 API Catalog pointer (root-served linkset). Lives under
          # the experimental `x-kiosk` namespace — agents.json v1.0 has no
          # standard link-catalog key, so we do NOT force a top-level field.
          api_catalog: "/.well-known/api-catalog",
          mount_path:  config.mount_path,
          api_version: Kiosk::Protocol::API_VERSION,
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
      # array hyperlinks the live API endpoints — the two service
      # DESCRIPTIONS, then EVERY REGISTERED VERB at its own 0.4 endpoint, then
      # `pay` and the agents.json discovery companion.
      #
      # The `schema` endpoint is the machine-readable surface description, so it
      # carries the RFC 9727 `service-desc` relation (SHOULD); so does the
      # DERIVED `openapi.json` beside it ({OpenApi}), which describes the same
      # verbs in a form generic OpenAPI tooling can consume. Every other link is
      # a plain `item`.
      #
      # ── WHY IT HYPERLINKS EVERY REGISTERED VERB (K-799 = b, T-093) ───────
      #
      # It did not, until 2026-08-19. Slice 5 withheld the verb names because
      # this document is served UNAUTHENTICATED at the origin root, and three
      # separate places had paid a design cost to keep the catalogue behind a
      # token. Phil overruled the premise rather than the arithmetic: «на
      # статичных GET endpoint'ах — пожалуйста… Пускай долбятся в них сколько
      # хотят без аутентификации». The verb roster is not a secret, and a
      # document composed from in-process state caches behind a CDN, so
      # anonymous enumeration costs this origin nothing.
      #
      # THE ACCEPTANCE HAS A CONDITION, and this renderer is what keeps it
      # true: it covers documents that are CHEAP AND STATIC TO COMPOSE. Every
      # value below comes from `config` or from the two registries — no query,
      # no per-request work, no caller-dependent branch. A future member that
      # needed a backend call would NOT be covered by that answer and would be
      # a fresh question, not a bigger loop.
      #
      # ── The RFC reading, re-settled (T-093) ──────────────────────────────
      #
      # Slice 5 read RFC 9727 strictly: a catalog lists APIs and points at
      # their DESCRIPTIONS, so members were `service-desc` links. Phil's answer
      # overruled the security objection, not that reading — so BOTH survive
      # here. The two `service-desc` members stay exactly as they were, and the
      # per-verb operations are added ALONGSIDE them as plain `item`s. A
      # consumer that only understands `service-desc` still finds the whole
      # surface described; one that wants the operations finds them hyperlinked
      # without parsing a description first.
      #
      # A verb's METHOD rides an EXTENSION target attribute, `kiosk-method`,
      # serialized as an array of strings per RFC 9264 §4.2.4.3 (that is how a
      # linkset+json document carries a non-registered attribute). It is needed
      # because a query and an action differ only by method — `rel` cannot say
      # it, and a bare href would invite a `GET` at an action's path, which is
      # a `405`.
      #
      # @return [Hash]
      def self.api_catalog(base_url:, config: Kiosk.configuration)
        validate_issuer!(config)
        base = base_url.to_s.chomp("/")
        endpoint = base + config.mount_path
        modules = Array(config.capabilities)

        items = []
        # schema is the machine-readable service description (service-desc).
        if modules.include?("schema")
          # BOTH DESCRIPTIONS ARE LINKED AT `?v=<version>` (K-804). This
          # document is a POINTER — short TTL, re-read often — and the two it
          # points at are large, identical for every caller and immutable at a
          # versioned url. A pointer that links the BARE path hands its reader
          # the one url that may not be cached, which is the whole conflict
          # `schema_url` was introduced to resolve in {build}; the api-catalog
          # had simply never been given the same treatment. One version serves
          # both links: {SchemaDocument.digest} covers every input of either
          # renderer (see {SchemaDocument.digest_inputs}).
          version = SchemaDocument.digest(config: config)
          items << { href: "#{endpoint}/schema?v=#{version}", rel: "service-desc" }
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
          items << { href: "#{endpoint}/openapi.json?v=#{version}", rel: "service-desc" }
        end
        # EVERY REGISTERED VERB, at its own 0.4 endpoint, with the method that
        # reaches it: a query is a GET, an action is a POST. Sorted by name
        # within each kind so the document is byte-stable across boots — a
        # linkset whose member order wobbled would break its own ETag for no
        # reason. Queries before actions, which is `capabilities`' order too.
        Queries.known.sort.each do |name|
          items << verb_item(endpoint, name, "GET")
        end
        Actions.known.sort.each do |name|
          items << verb_item(endpoint, name, "POST")
        end
        # The remaining modules are plain catalogued APIs, one link each —
        # which since the cutover means `pay` and nothing else (see
        # MODULE_ENDPOINTS).
        MODULE_ENDPOINTS.each do |mod, path|
          items << { href: "#{endpoint}/#{path}", rel: "item" } if modules.include?(mod)
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
          - Verb catalogue (PUBLIC, no token): `#{endpoint}/schema`
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
          on the wire verbs too, and most of them are GETs, which have no body
          to carry a proof. The ONE endpoint under `#{endpoint}` that is never
          tolled is `GET #{endpoint}/schema`: it is public, it is served from
          memory, and a toll needs an identity to charge.

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
          under `#{endpoint}` — every query, every action, and `pay`. Tokens
          are RS256 JWTs verifiable against the JWKS above.
          `GET #{endpoint}/schema` is the exception: it is PUBLIC, so read
          the catalogue before you register if you like.

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

      # One linkset member for one registered verb (T-093). `rel: "item"` is
      # RFC 9727's catalogued-API relation; `kiosk-method` is the extension
      # target attribute carrying the HTTP method, an ARRAY OF STRINGS because
      # RFC 9264 §4.2.4.3 serializes every extension attribute that way.
      def self.verb_item(endpoint, name, method)
        { href: "#{endpoint}/#{name}", rel: "item", "kiosk-method": [method] }
      end
      private_class_method :verb_item

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

      # Whether this deployment serves the `pay` MODULE — the canonical gate
      # for advertising AP2/payments across the discovery surfaces.
      # `capabilities` is the computed module set; `pay` drops out when no
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
