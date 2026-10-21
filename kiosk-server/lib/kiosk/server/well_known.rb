# frozen_string_literal: true

require 'json'
require 'uri'

module Kiosk
  module Server
    # The discovery documents — kiosk.json, agents.txt, agents.json, the OAuth
    # metadata (RFC 8414, RFC 9728), the skills index, ard.json, api-catalog and auth.md — rendered
    # as pure functions of one configuration and the request's base URL, so they
    # cannot drift.
    module WellKnown
      DOCUMENT_VERSION = '1.0'

      AGENTS_VERSION  = '1.0'
      AGENTS_STANDARD = 'https://agents-txt.com'
      AGENTS_SCHEMA   = 'https://agents-txt.com/schema/agents-json/v1.0.json'

      # agents.txt v1.0 names OAuth 2.0 `oauth2`. Its discovery document is the RFC 8414 metadata.
      AUTHORIZATION = { protocols: %w[oauth2], discovery: '/.well-known/oauth-authorization-server' }.freeze

      SKILLS_INDEX_SCHEMA = 'https://schemas.agentskills.io/discovery/0.2.0/schema.json'

      # AI Catalog requires `specVersion`; ARD v0.91 ignores it.
      AI_CATALOG_VERSION = '1.0'

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

      # `/.well-known/oauth-authorization-server` (RFC 8414): registration,
      # tokens, and the device-code grant where the origin serves binding.
      def self.oauth_authorization_server(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        base = base_url.to_s.chomp('/')
        endpoint = base + config.mount_path
        doc = { issuer: Kiosk.current_issuer, registration_endpoint: "#{endpoint}/oauth/register",
                token_endpoint: "#{endpoint}/oauth/token" }
        doc[:device_authorization_endpoint] = "#{endpoint}/oauth/device_authorization" if config.serve_account_binding
        # No authorization endpoint, so no response type.
        doc.merge(jwks_uri: "#{endpoint}/.well-known/jwks.json", response_types_supported: [],
                  grant_types_supported: Client.grant_types(config), **Shared.client_authentication,
                  service_documentation: "#{base}/auth.md", dpop_signing_alg_values_supported: AssistantKey::ALGORITHMS)
      end

      # `/.well-known/oauth-protected-resource` (RFC 9728). RFC 9728 §3.3 binds a
      # document at this path to the origin, so `resource` is the origin.
      def self.oauth_protected_resource(base_url:, config: Kiosk.configuration)
        Shared.validate_issuer!(config)
        base = base_url.to_s.chomp('/')
        { resource: base, authorization_servers: [Kiosk.current_issuer], bearer_methods_supported: ['header'],
          dpop_signing_alg_values_supported: AssistantKey::ALGORITHMS, dpop_bound_access_tokens_required: true,
          resource_documentation: "#{base}/auth.md" }
      end

      # `/.well-known/agent-skills/index.json` (Agent Skills Discovery v0.2.0):
      # the pinned skill and its digest. nil without a `skill_sha256`.
      def self.agent_skills_index(config: Kiosk.configuration)
        return unless Shared.skill?(config) && config.skill_sha256

        { '$schema': SKILLS_INDEX_SCHEMA,
          skills: [{ name: SKILL_NAME, type: 'skill-md', description: SKILL_DESCRIPTION,
                     url: config.skill_url, digest: "sha256:#{config.skill_sha256}" }] }
      end

      # `/.well-known/ard.json` (Agentic Resource Discovery v0.91), also served
      # at `/.well-known/ai-catalog.json` (AI Catalog 1.0): this origin's
      # kiosk.json and the skill that reads it.
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
        { specVersion: AI_CATALOG_VERSION, entries: entries }
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

        # RFC 8414: how a client authenticates at the token endpoint.
        def client_authentication
          { token_endpoint_auth_methods_supported: [Client::AUTH_METHOD],
            token_endpoint_auth_signing_alg_values_supported: AssistantKey::ALGORITHMS }
        end

        # Every URL, also the binding ones: where binding is not served they answer 501.
        def auth_section(endpoint)
          auth_urls(endpoint).transform_keys { |step| :"#{step}_url" }
        end

        def auth_urls(endpoint)
          {
            registration: "#{endpoint}/oauth/register",
            token: "#{endpoint}/oauth/token",
            rotate: "#{endpoint}/auth/rotate",
            device_authorization: "#{endpoint}/oauth/device_authorization",
            claim: "#{endpoint}/auth/claim"
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
                'is the origin a token or a checkout names'
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
            auth.md section order. Registration and tokens use OAuth 2.0
            standards: RFC 7591, RFC 7523, RFC 9449 and RFC 8628.

            ## Discover

            - This file: `#{base}/auth.md`
            - Kiosk discovery document: `#{base}/.well-known/kiosk.json`
            - OAuth metadata of this authorization server (RFC 8414): `#{base}/.well-known/oauth-authorization-server`
            - OAuth metadata of this protected resource (RFC 9728): `#{base}/.well-known/oauth-protected-resource`
            - Verb catalogue (PUBLIC, no token): `#{endpoint}/schema`
            - Token-verification keys (JWKS): `#{endpoint}/.well-known/jwks.json`
            #{skill_line}

            ## Pick a method

            - **Open registration** — supported. You register your own RSA
              public key (RFC 7591). No human account is necessary. You
              authenticate each token request with a client assertion that
              your key signs (`private_key_jwt`, RFC 7523).
            - **Claim ceremony** — supported. It binds your registered client
              to an EXISTING account after its holder approves in their own
              browser session (RFC 8628).
            - **Link code** — supported. The account holder makes a
              single-use code on the provider's site and gives it to you.
            - **Identity assertion (ID-JAG)** — not supported (planned).

            ## Register

            1. Make one RSA key of 2048 bits for this provider. Keep the
               private key.
            2. `POST #{urls[:registration]}` with `Content-Type: application/json`:

                   {"jwks":{"keys":[{"kty":"RSA","n":"…","e":"AQAB"}]},
                    "token_endpoint_auth_method":"private_key_jwt"}

               → `201 { client_id, client_id_issued_at, jwks,
               token_endpoint_auth_method, grant_types, dpop_bound_access_tokens }`
            3. Keep `client_id`. Registration gives no token.

            If you register a key that has a live client here, you get that
            client again, with the same `client_id`. If the `client_id` is
            new, the account holder unlinked your old client: ask them before
            you continue. A body that is not correct gets
            `400 { "error": "invalid_client_metadata", "error_description" }`.

            Registration can have an Equihash proof-of-work toll. Then the
            request gets `402 pow_required` with
            `WWW-Authenticate: Kiosk-PoW realm="<issuer>"` and a `challenges`
            array in the body. The toll is bound to the key that you
            register. Solve EVERY challenge. Then send the SAME body again,
            with the proofs in a `Kiosk-PoW` REQUEST HEADER as raw minified
            JSON (no base64):

                Kiosk-PoW: {"challenge":{…},"nonce":{"indices":[…],"header_nonce":0}}

            Send N proofs as a JSON array in that one header, or as one
            `Kiosk-PoW` header line for each proof. A proof is never in the
            request body: the operator ignores a body `pow` field, and a
            changed body makes the proofs incorrect. The same header answers a
            `402 pow_required` on the wire verbs too. Most of them are GETs,
            which have no body. The ONE endpoint under `#{endpoint}` that has
            no toll is `GET #{endpoint}/schema`: it is public, the operator
            serves it from memory, and a toll needs an identity to charge.

            Do not write your own Equihash solver. The verifier is exact about
            the seed construction, the index width and the tree order. A
            mismatch gets `403 forbidden`, and the answer does not say which
            check failed. Get the reference solver from
            `#{PowGate::POW_SOLVER_URL}`. The 403 `hint` names the same file.
            That URL has no version and always serves the CURRENT solver.
            Before you run it, compare its SHA-256 with the pin that the wire
            skill above publishes.

            ## Claim ceremony

            A client assertion is a compact RS256 JWT that your registered key
            signs. Its payload is `{iss, sub, aud, exp, jti}`: `iss` and `sub`
            are your `client_id`, `aud` is the origin you connected to (take it
            from your own request URL), `exp` is at most 300 seconds from now,
            and `jti` is a new unique id. Send it as `client_assertion`, with
            `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`.
            The operator accepts each `jti` one time.

            Claim binding (RFC 8628) binds YOUR client to the account holder's
            existing account. The codes are single-use and short-lived:

            1. `POST #{urls[:device_authorization]}` (form-encoded:
               `client_assertion_type`, `client_assertion`) →
               `{ device_code, user_code, verification_uri, verification_uri_complete, expires_in, interval }`
            2. Tell the holder: "open <verification_uri>, enter <user_code>".
               They approve in their own signed-in browser session.
            3. Poll `POST #{urls[:token]}` (form-encoded:
               `grant_type=urn:ietf:params:oauth:grant-type:device_code`,
               `device_code`, `client_assertion_type`, `client_assertion`),
               with a `DPoP` header as in Exchange. When the holder approves,
               the answer is a token under the holder's account.

            Link flow (the opposite direction): the holder makes a code on the
            provider's site and gives it to you. Send
            `POST #{urls[:claim]}` `{ code, client_assertion_type, client_assertion }`
            → `204 No Content`. Then get a token as in Exchange.

            Where registration has a toll, the link-code claim and the FIRST
            token poll of each `device_code` have the same toll. It comes
            before the operator reads the code. Solve it as for registration
            and send the SAME request again with the `Kiosk-PoW` header. Later
            polls of the same `device_code` have no toll.

            A binding keeps your `client_id` and your reputation. Your client
            moves to the holder's account and gets the holder's role.

            ## Exchange

            `POST #{urls[:token]}`, form-encoded:
            `grant_type=client_credentials`, `client_assertion_type`,
            `client_assertion`. Add a `DPoP` header (RFC 9449): a JWS with
            `typ` `dpop+jwt`, `alg` RS256 and the public `jwk` of your
            registered key, that the key signs, with the payload
            `{jti, htm: "POST", htu: "#{urls[:token]}", iat}`. A token
            request has no `ath`.
            → `200 { access_token, token_type: "DPoP", expires_in, scope }`.
            `scope` is your role, and it is there only when you have a role.

            To get a new token, do this request again: no ceremony repeats.
            If you get `invalid_client`, sign a new assertion one time. If
            that also fails, register your key again.

            ## Use the access_token

            Send `Authorization: DPoP <access_token>` to the wire verbs
            under `#{endpoint}` (every query, every action, and `pay`) with a
            `DPoP` header: a proof (RFC 9449) that your registered key signs
            for that method and URL, with `ath`, the hash of the token. A
            token is bound to that key and works with no other key. Tokens are
            RS256 JWTs that the JWKS above verifies.
            `GET #{endpoint}/schema` is the exception: it is PUBLIC, so you
            can read the catalogue before you register.

            ## Errors

            - Kiosk endpoints (`/auth/*`, `pay`, every query and every action)
              answer an error as an RFC 9457 problem document, served as
              `application/problem+json`:

                  {"type":"https://kiosk.tech/problems/pow_required",
                   "title":"Proof-of-work required","status":402,
                   "detail":"proof-of-work required","code":"pow_required"}

              Use `code` to decide what to do. It is a FLAT member of the
              document, not nested, from the closed vocabulary
              (`unauthenticated`, `not_found`, `conflict`, `pow_required`, …);
              `type` is `https://kiosk.tech/problems/<code>` and names the same
              fact. Some codes add members of their own, such as the
              `challenges` array on a `402 pow_required`.
            - Three codes say "it is not here", and each has a different
              meaning. `404 verb_not_found`: no verb with that NAME is
              registered here; `hint` lists the verbs that are, so read the
              catalogue again and call a verb that exists. `404 not_found`:
              the verb is real and an ARGUMENT names something that is not
              there; the answer is final, so stop. `501 module_not_served`:
              this origin does not serve that optional module (binding,
              payment, KYC, the event stream; `detail` names which); do not
              retry, and do what you would do at an operator that never
              offered it.
            - The OAuth endpoints (`/oauth/*`) use the OAuth error shape
              `{ error, error_description }`. Two answers there are problem
              documents: `501 module_not_served` where the origin does not
              serve binding, and the toll (`402 pow_required` and its
              refusals of a proof). Registration has one code,
              `invalid_client_metadata`. The token and device-authorization
              codes are a closed set of nine: `invalid_request`,
              `invalid_client`, `invalid_grant`, `unsupported_grant_type`,
              `invalid_dpop_proof` (RFC 9449), and the ceremony codes
              `authorization_pending`, `slow_down`, `expired_token`,
              `access_denied` (RFC 8628 §3.5). Every code answers `400`,
              except `invalid_client`, which answers `401`.

            ## Revocation

            - Key rotation: `POST #{urls[:rotate]}`
              `{ client_assertion_type, client_assertion, new_client_assertion, jwks }`
              puts the new key in `jwks` on your client. Your registered key
              signs `client_assertion`, with `new_key`, the RFC 7638
              thumbprint of the new key, in its payload. The new key signs
              `new_client_assertion` for the same `client_id`. The answer is
              your client information with the new key. Your `client_id` and
              your reputation stay. Every earlier token stops. Get a new token
              with the new key.
            - Unlink: the account holder, or the provider, deactivates your
              client (`POST #{endpoint}/auth/unlink`, authenticated by the
              holder's session, or the provider's linked-assistants page).
              Its tokens stop, and the token endpoint answers it
              `invalid_client`. It does NOT become a standalone account.
          MARKDOWN
        end
      end
    end
  end
end
