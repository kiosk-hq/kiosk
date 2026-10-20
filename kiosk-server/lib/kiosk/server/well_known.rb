# frozen_string_literal: true

require 'json'
require 'uri'

module Kiosk
  module Server
    # The discovery documents — kiosk.json, agents.txt, agents.json, the OAuth
    # metadata, the skills index, ard.json, api-catalog and auth.md — rendered
    # as pure functions of one configuration and the request's base URL, so they
    # cannot drift.
    module WellKnown
      DOCUMENT_VERSION = '1.0'

      AGENTS_VERSION  = '1.0'
      AGENTS_STANDARD = 'https://agents-txt.com'
      AGENTS_SCHEMA   = 'https://agents-txt.com/schema/agents-json/v1.0.json'

      # agents.txt v1.0 registers no identifier for kiosk-pop, so it takes the
      # standard's `x-` prefix. Its discovery document is kiosk.json.
      AUTHORIZATION = { protocols: %w[x-kiosk-pop], discovery: '/.well-known/kiosk.json' }.freeze

      DEVICE_CODE_GRANT = 'urn:ietf:params:oauth:grant-type:device_code'

      SKILLS_INDEX_SCHEMA = 'https://schemas.agentskills.io/discovery/0.2.0/schema.json'

      # The `name` and `description` of the pinned skill's frontmatter.
      # kiosk-test-support's skill_pin_spec holds them to the published cut.
      SKILL_NAME = 'kiosk-agent-protocol'
      SKILL_DESCRIPTION = 'A protocol that lets an AI assistant use the service of any Kiosk operator -- ' \
                          'a shop, a booking desk, a job board, a classifieds board, or data, not only ' \
                          'commerce. Register, read the catalogue to learn the operations, then act: ' \
                          'browse, order, book, apply, pay -- and subscribe to the operator\'s event ' \
                          'stream for anything that you would otherwise wait for.'

      ARD_API = 'The Kiosk discovery document of this origin: the endpoint, the sign-in and the catalogue. ' \
                'Read it with the Kiosk skill.'

      # `/.well-known/kiosk.json`.
      def self.build(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        endpoint = base_url.to_s.chomp('/') + config.mount_path
        kiosk = Shared.kiosk_document(endpoint, config)
        # Only when a topic is registered: advertise what is served.
        kiosk[:events_url] = "#{endpoint.sub(/\Ahttp/, 'ws')}/events" if Kiosk::Server::Events.known.any?

        kiosk[:skill] = { url: config.skill_url, sha256: config.skill_sha256 } if config.skill_sha256

        { kiosk: kiosk }
      end

      def self.build_json(**)
        JSON.generate(build(**))
      end

      # agents.txt v1.0 (agents-txt.com).
      def self.agents_txt(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        base = base_url.to_s.chomp('/')

        lines = ['# agents.txt — https://agents-txt.com', "# JSON: #{base}/agents.json"]
        lines.push('', "Authorization: #{AUTHORIZATION[:protocols].join(', ')}")
        lines.push('', "Skills: #{config.skill_url}") if Shared.skill?(config)

        "#{lines.join("\n")}\n"
      end

      # agents.json v1.0.
      def self.agents_json(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        doc = { '$schema': AGENTS_SCHEMA, version: AGENTS_VERSION, standard: AGENTS_STANDARD,
                site: { name: site_name(config), url: base_url.to_s.chomp('/') },
                authorization: AUTHORIZATION }
        doc[:skills] = [{ url: config.skill_url, description: SKILL_DESCRIPTION }] if Shared.skill?(config)
        doc
      end

      # `/.well-known/oauth-authorization-server` (RFC 8414): the binding
      # ceremony's device-code grant. nil when the origin serves no binding.
      def self.oauth_authorization_server(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        return unless config.serve_account_binding

        base = base_url.to_s.chomp('/')
        endpoint = base + config.mount_path
        { issuer: Kiosk.current_issuer, token_endpoint: "#{endpoint}/oauth/token",
          device_authorization_endpoint: "#{endpoint}/oauth/device_authorization",
          jwks_uri: "#{endpoint}/.well-known/jwks.json",
          # No authorization endpoint, so no response type.
          response_types_supported: [], grant_types_supported: [DEVICE_CODE_GRANT],
          token_endpoint_auth_methods_supported: ['none'], service_documentation: "#{base}/auth.md" }
      end

      # `/.well-known/agent-skills/index.json` (Agent Skills Discovery v0.2.0):
      # the pinned skill and its digest. nil without a `skill_sha256`.
      def self.agent_skills_index(config: Kiosk.configuration)
        return unless Shared.skill?(config) && config.skill_sha256

        { '$schema': SKILLS_INDEX_SCHEMA,
          skills: [{ name: SKILL_NAME, type: 'skill-md', description: SKILL_DESCRIPTION,
                     url: config.skill_url, digest: "sha256:#{config.skill_sha256}" }] }
      end

      # `/.well-known/ard.json` (Agentic Resource Discovery v0.91): this
      # origin's kiosk.json and the skill that reads it.
      def self.ard(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        base = base_url.to_s.chomp('/')
        urn = "urn:air:#{URI.parse(base).host}:kiosk"
        entries = [{ identifier: "#{urn}:api", displayName: "#{site_name(config)} Kiosk endpoint",
                     type: 'application/json', url: "#{base}/.well-known/kiosk.json", description: ARD_API }]
        if Shared.skill?(config)
          entries << { identifier: "#{urn}:skill", displayName: SKILL_NAME, type: 'application/agent-skills+md',
                       url: config.skill_url, description: SKILL_DESCRIPTION }
        end
        { entries: entries }
      end

      # `/.well-known/api-catalog` (RFC 9727): every verb as an `item` of the
      # catalog, its method in the `kiosk-method` extension attribute, and the
      # two service descriptions on the endpoint. Composed from configuration
      # and the registries only, never a query.
      def self.api_catalog(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        base = base_url.to_s.chomp('/')
        endpoint = base + config.mount_path
        modules = Array(config.capabilities)

        linkset = [{ anchor: "#{base}/.well-known/api-catalog",
                     item: Catalog.verb_items(endpoint) + Catalog.module_items(endpoint, modules) }]
        descs = Catalog.service_descs(endpoint, modules, config)
        linkset << { anchor: endpoint, 'service-desc': descs } if descs.any?
        { linkset: linkset }
      end

      # `/auth.md`: the auth methods in auth.md's section order.
      def self.auth_md(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        base = base_url.to_s.chomp('/')
        endpoint = base + config.mount_path

        AuthMd.render(site: site_name(config), base: base, endpoint: endpoint,
                      urls: Shared.auth_urls(endpoint), skill_line: Shared.skill_discover_line(config))
      end

      # The owner's name, else the issuer's host. Also titles the OpenAPI document.
      def self.site_name(config)
        name = config.owner.is_a?(Hash) ? config.owner[:name] : nil
        return name if name && !name.to_s.empty?

        Shared.host_of(Kiosk.current_issuer)
      end

      # The parts the discovery documents share.
      module Shared
        module_function

        def kiosk_document(endpoint, config)
          {
            version: DOCUMENT_VERSION,
            endpoint: endpoint,
            auth: auth_section(endpoint),
            # The modules served, not the verb names; published here only.
            capabilities: Array(config.capabilities),
            # Versioned, so the catalog may be cached for a year at this URL.
            schema_url: "#{endpoint}/schema?v=#{SchemaDocument.digest(config: config)}",
            min_client: Kiosk::Protocol::MIN_CLIENT,
            issuer: Kiosk.current_issuer,
            owner: config.owner
          }
        end

        def auth_section(endpoint)
          {
            kind: 'kiosk-pop',
            **auth_urls(endpoint).transform_keys { |step| :"#{step}_url" },
            # Additive: a client that ignores binding still has register/login.
            device_authorization_url: "#{endpoint}/oauth/device_authorization",
            claim_url: "#{endpoint}/auth/claim"
          }
        end

        def auth_urls(endpoint)
          {
            challenge: "#{endpoint}/auth/challenge",
            register: "#{endpoint}/auth/register",
            login: "#{endpoint}/auth/login",
            revoke: "#{endpoint}/auth/revoke"
          }
        end

        def host_of(issuer)
          URI.parse(issuer.to_s).host || issuer.to_s
        rescue URI::InvalidURIError
          issuer.to_s
        end

        def skill_discover_line(config)
          return '' unless skill?(config)

          sha = config.skill_sha256
          line = "- Wire skill for AI assistants: `#{config.skill_url}`"
          line += " (sha256 `#{sha}`)" if sha && !sha.to_s.empty?
          line
        end

        def skill?(config)
          !config.skill_url.to_s.empty?
        end

        def validate_issuer!(config)
          return if config.issuer && !config.issuer.to_s.empty?

          raise ArgumentError,
                'Kiosk.configuration.issuer must be set before serving ' \
                '/.well-known/kiosk.json — the issuer ' \
                'is the AP2 mandate `iss` anchor'
        end
      end

      # The api-catalog's links.
      module Catalog
        module_function

        # Versioned links: this pointer is short-lived, its targets are immutable.
        # The only place the derived OpenAPI document is advertised.
        def service_descs(endpoint, modules, config)
          return [] unless modules.include?('schema')

          version = SchemaDocument.digest(config: config)
          [{ href: "#{endpoint}/schema?v=#{version}", type: 'application/json' },
           { href: "#{endpoint}/openapi.json?v=#{version}", type: OpenApi::CONTENT_TYPE }]
        end

        # Sorted, so the document is byte-stable across boots.
        def verb_items(endpoint)
          Queries.known.sort.map { |name| verb_item(endpoint, name, 'GET') } +
            Actions.known.sort.map { |name| verb_item(endpoint, name, 'POST') }
        end

        def module_items(endpoint, modules)
          modules.include?('pay') ? [verb_item(endpoint, 'pay', 'POST')] : []
        end

        # RFC 9264 §4.2.4.3: an extension attribute is an array of strings.
        def verb_item(endpoint, name, method)
          { href: "#{endpoint}/#{name}", 'kiosk-method': [method] }
        end
      end

      # The `/auth.md` document.
      # rubocop:disable-next Metrics/ModuleLength -- one Markdown document; its lines are prose
      module AuthMd
        def self.render(site:, base:, endpoint:, urls:, skill_line:)
          <<~MARKDOWN
            # auth.md — #{site}

            How AI assistants authenticate against this provider's Kiosk
            endpoint (`#{endpoint}`). Wire contract: the Kiosk specification
            (https://kiosk.tech/specification.html). This file follows the
            auth.md section order. The provider does not serve the auth.md
            registration endpoints: register with kiosk-pop as below.

            ## Discover

            - This file: `#{base}/auth.md`
            - Kiosk discovery document: `#{base}/.well-known/kiosk.json`
            - OAuth metadata of the claim ceremony (RFC 8414): `#{base}/.well-known/oauth-authorization-server`
            - Verb catalogue (PUBLIC, no token): `#{endpoint}/schema`
            - Token-verification keys (JWKS): `#{endpoint}/.well-known/jwks.json`
            #{skill_line}

            ## Pick a method

            - **kiosk-pop** — supported. Self-registration of a per-provider
              RSA keypair: no human account needed. Every register and login
              carries a proof that you hold the private key.
            - **Claim ceremony** — supported. It binds an agent key to an
              EXISTING account after its holder approves in their own browser
              session.
            - **Link code** — supported. The account holder mints a
              single-use code on the provider's site and hands it to the
              assistant.
            - **Identity assertion (ID-JAG)** — not supported (planned).

            ## Register

            kiosk-pop self-registration:

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

            Do not write your own Equihash solver. The verifier is exact about
            the seed construction, the index width and the tree ordering, and a
            mismatch comes back `403 forbidden` with no indication of which check
            failed. Fetch the reference solver from
            `#{PowGate::POW_SOLVER_URL}` — the same file that 403's `hint` names.
            That URL is unversioned and always serves the CURRENT solver, so
            check its SHA-256 against the content-addressed pin the wire skill
            above publishes before you execute it.

            ## Claim ceremony

            Claim binding (RFC 8628 wire) — binds YOUR key to the
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

            Link flow (the mirror direction): the holder mints a
            code on the provider's site and pastes it to you; redeem with
            `POST #{endpoint}/auth/claim` `{ code, public_key, signed }`
            → `201 { agent_id, user_id, access_token }`.

            Where registration has a toll, the link-code claim and the FIRST
            token poll of each `device_code` have the same toll. It comes
            before the code is looked up. Solve it as for register and send the
            SAME request again with the `Kiosk-PoW` header. Later polls of the
            same `device_code` are free.

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

            - Kiosk endpoints (`/auth/*`, `pay`, every query and every action)
              answer an error as an RFC 9457 problem document, served as
              `application/problem+json`:

                  {"type":"https://kiosk.tech/problems/pow_required",
                   "title":"Proof-of-work required","status":402,
                   "detail":"proof-of-work required","code":"pow_required"}

              Branch on `code` — a FLAT member of the document, not nested — from
              the closed vocabulary (`unauthenticated`, `not_found`, `conflict`,
              `pow_required`, …); `type` is `https://kiosk.tech/problems/<code>`
              and names the same fact. Some codes add members of their own, such
              as the `challenges` array on a `402 pow_required`.
            - Three codes say "it is not here" and they mean three different
              things. `404 verb_not_found` — no verb by that NAME is registered
              here; `hint` lists the ones that are, so re-read the catalogue and
              call something that exists. `404 not_found` — the verb is real and
              an ARGUMENT addressed something absent; the answer is final, so
              stop. `501 module_not_served` — this origin does not serve that
              optional module at all (binding, payment, KYC, the event stream;
              `detail` names which); do not retry, and fall back to what you
              would do at an operator that never offered it.
            - The claim ceremony's OAuth endpoints use the OAuth error shape
              `{ error, error_description }` — a documented exception, and the
              only one, with two carve-outs that are ordinary problem documents:
              an origin that does not serve binding at all answers
              `501 module_not_served` there, because none of the OAuth codes
              means it, and the toll on the token poll answers as the toll does
              everywhere (`402 pow_required`, and its refusals of a proof). The
              OAuth vocabulary is closed at eight. Six describe the
              ceremony (RFC 8628 §3.5): `authorization_pending`, `slow_down`,
              `expired_token`, `access_denied`, `invalid_grant`,
              `invalid_client`. Two are request-level (RFC 6749 §5.2):
              `invalid_request` — a required parameter absent or malformed, or
              one the request must not carry, such as a `role`/`scope` on the
              device-authorization call — and `unsupported_grant_type` for any
              grant but the device-code one. Everything answers `400` except
              `invalid_client`, which answers `401`.

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
      end
    end
  end
end
