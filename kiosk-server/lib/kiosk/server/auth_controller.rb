# frozen_string_literal: true

# The kiosk-pop auth surface. The engine draws the routes; hand-drawing them
# in the host's config/routes.rb remains the escape hatch.

require "action_controller"
require "json"
require "kiosk/server/agent_registration"
require "kiosk/server/agent_login"
require "kiosk/server/auth_challenge"
require "kiosk/server/account_binding"
require "kiosk/server/link_code"
require "kiosk/server/errors"
require "kiosk/server/headers"
require "kiosk/server/pow_gate"
require "kiosk/server/request_validation"

module Kiosk
  module Server
    # PoP auth surface (challenge-response). One controller; the four
    # kiosk-pop actions:
    #
    #   GET  /kiosk/auth/challenge?public_key=…            → { challenge, exp }
    #   POST /kiosk/auth/register  { public_key, signed }
    #                                (optional PoW proof: `Kiosk-PoW` header)
    #                                → 201 { user_id, agent_id, access_token }
    #   POST /kiosk/auth/login     { public_key, signed }  → 200 { access_token }
    #   POST /kiosk/auth/revoke    (Bearer)                → 200 { access_token }
    #
    # plus the link half of the account-binding ceremony (a
    # Kiosk extension; the agent-initiated claim half lives on the OAuth
    # controllers):
    #
    #   POST /kiosk/auth/link      (user_idp session)      → 201 { link_code, expires_in }
    #   POST /kiosk/auth/claim     { code, public_key, signed }
    #                                → 201 { agent_id, user_id, access_token }
    #   POST /kiosk/auth/unlink    (user_idp session, { agent_id })
    #                                → 204 No Content
    #
    # `signed` is a compact RS256 JWS (see {PopVerifier}) proving the caller
    # holds the private key — and, via its `aud` claim, binding the proof to
    # THIS origin so it can't be relayed. See kiosk.tech/specification.html.
    class AuthController < ::ActionController::API
      # Issue a single-use, short-lived challenge nonce for a public key.
      # Unauthenticated by design: the caller has no token yet, and the nonce
      # is worthless to anyone without the matching private key.
      def challenge
        public_key = request.query_parameters["public_key"]
        if public_key.nil? || public_key.empty?
          raise Errors::BadRequest.new("missing public_key query parameter")
        end

        respond(AuthChallenge.issue(public_key_pem: public_key), :ok)
      rescue Errors::Base => e
        render_error(e)
      end

      # Register a NEW public key (409 if already registered → use /login).
      #
      # The optional registration PoW proof rides in the `Kiosk-PoW` request
      # HEADER (ADR-0022), not the body — the same header the wire verbs use.
      # The signed body stays pow-free so the challenge fingerprint (bound to
      # the registering public key) matches on retry.
      def register
        body   = parse_body!
        pow    = PowGate.proofs_from_header(request.get_header("HTTP_KIOSK_POW"))
        if Kiosk.configuration.validate_requests && !PowGate.blank?(pow)
          RequestValidation.validate_proofs!(pow)
        end
        result = AgentRegistration.call(
          public_key_pem: body.fetch(:public_key),
          signed:         body.fetch(:signed),
          pow:            pow,
        )
        respond(result, :created)
      rescue KeyError => e
        render_error(Errors.missing_field(e))
      rescue Errors::Base => e
        render_error(e)
      end

      # Refresh a token for an EXISTING public key (404 if unknown → register).
      def login
        body   = parse_body!
        result = AgentLogin.call(
          public_key_pem: body.fetch(:public_key),
          signed:         body.fetch(:signed),
        )
        respond(result, :ok)
      rescue KeyError => e
        render_error(Errors.missing_field(e))
      rescue Errors::Base => e
        render_error(e)
      end

      # Revoke EVERY token for the caller's identity ("log out other
      # sessions") and hand back a fresh one — so the call doesn't log the
      # caller out of the session it is using.
      def revoke
        identity = authenticated_agent
        if identity.nil? || identity.agent_id.nil?
          raise Errors::Unauthenticated, "agent authentication required"
        end

        Kiosk.configuration.revocation_store&.revoke_all(identity.agent_id, at: Time.now.to_i)
        # kiosk-pop endpoints mint their own tokens via the bundled
        # DefaultAgentIdp by design; adapter-supplied issuance
        # is the 0.2 seam.
        token = AgentIdentityProviders::DefaultAgentIdp.new.issue(
          agent_id: identity.agent_id, role: identity.role,
        )
        respond({ access_token: token }, :ok)
      rescue Errors::Base => e
        render_error(e)
      end

      # Mint a link code for the signed-in assistant-account holder
      # (session channel — binding approval belongs to the
      # provider's own session auth). The human hands the code to their
      # assistant, which redeems it at POST /auth/claim.
      #
      # roles-from-IdP (Path A): the human's own role — as the
      # provider's `user_idp` reports it (`identity.role`) — is captured
      # onto the link row's `requested_role`, so the assistant bound at
      # claim time INHERITS the human's role (see {AccountBinding.bind!}).
      # A role-less `user_idp` reports `nil`; the binding then falls back
      # to `registration_role`/absent exactly as before (no regression).
      def link
        identity = authenticated_account_holder!
        result   = LinkCode.mint(user_id: identity.user_id, requested_role: identity.role)
        respond({ link_code: result[:link_code], expires_in: result[:expires_in] }, :created)
      rescue Errors::Base => e
        render_error(e)
      end

      # Redeem a link code: register-shaped body — the possession proof is
      # REQUIRED (BIND-POP), so a leaked request body alone can never bind
      # a key its holder does not control. Same fresh/rebind semantics as
      # the claim flow; same 201 shape as /auth/register.
      # The response is an explicit ALLOW-LIST of the three fields
      # `protocol.md` Section 6.2 specifies, not `bind!`'s return hash rendered
      # whole. That hash also carries `fresh:` — an internal signal saying
      # whether the key was newly registered or rebound — which was on the wire
      # on every claim while no published surface documented it (K-855). It is
      # withdrawn rather than specified: Section 6.3 requires that an
      # idempotent re-bind be indistinguishable from any other rebind (K-787),
      # so a field whose whole purpose is to distinguish binds is one an
      # assistant would reach for to defeat that, and nothing on the wire needs
      # it — the assistant already knows whether it had registered before.
      # Listing the fields also means the next field added to `bind!`'s result
      # has to be put on the wire deliberately instead of arriving there.
      CLAIM_RESPONSE_FIELDS = %i[agent_id user_id access_token].freeze

      def claim
        body   = parse_body!
        result = LinkCode.redeem(
          code:           body.fetch(:code),
          public_key_pem: body.fetch(:public_key),
          signed:         body.fetch(:signed),
        )
        respond(result.slice(*CLAIM_RESPONSE_FIELDS), :created)
      rescue KeyError => e
        render_error(Errors.missing_field(e))
      rescue Errors::Base => e
        render_error(e)
      end

      # Registration-layer revocation: the signed-in holder
      # deactivates one of THEIR linked assistant accounts. Token verify
      # and login deny the key from here on.
      #
      # ANSWERS `204 No Content` (K-870, Phil 2026-08-21). It used to render
      # `{ ok: true }` — a body no published surface documented, on an endpoint
      # whose two siblings ARE documented: `protocol.md` §6.2 spells out
      # `/auth/link -> {link_code, expires_in}` and `/auth/claim -> 201
      # {agent_id, user_id, access_token}`, and said nothing at all about what
      # unlink answers. That is the defect, and it is the same one K-855 fixed
      # by WITHDRAWING an undocumented field rather than specifying it. The
      # withdrawal is the cheaper true answer here because nothing read the
      # body: every caller in the tree — the e2e claim flow, philslist's and
      # stylish's binding beats, tudu's redteam suite — reads the STATUS.
      #
      # Deliberately NOT justified as "§8.2 forbids the `ok` envelope". §8.2 is
      # scoped to VERB response shape, not to the auth ceremony, so leaning on
      # it would put a citation into the spec that the spec does not support.
      # The body being an `ok` flag is a characterisation; the defect is that
      # it was undocumented.
      #
      # 204 is itself a wire fact, so §6.2 now says so beside the siblings.
      # `Headers.add_to` still runs: the three version-handshake headers ride
      # on every mount-path response (§3, point 6), empty body or not.
      def unlink
        identity = authenticated_account_holder!
        body     = parse_body!
        AccountBinding.unlink!(agent_id: body.fetch(:agent_id), user_id: identity.user_id)
        Kiosk::Server::Headers.add_to(response.headers)
        head :no_content
      rescue KeyError => e
        render_error(Errors.missing_field(e))
      rescue Errors::Base => e
        render_error(e)
      end

      private

      # Resolve the signed-in assistant-account holder via the provider's
      # `user_idp` session adapter. No session (or no adapter configured)
      # → 401: the binding surface never accepts agent Bearer tokens for
      # the human's side of the ceremony.
      def authenticated_account_holder!
        identity = Kiosk.configuration.user_idp&.verify(request)
        if identity.nil?
          raise Errors::Unauthenticated.new(
            "account session required",
            hint: "sign in to the provider first — this endpoint authenticates via the provider's own session",
          )
        end
        identity
      end

      # Resolve the caller's agent identity from its Bearer token. A missing,
      # invalid, or already-revoked token resolves to nil → 401.
      def authenticated_agent
        IdentityResolution.agent_idp.verify(request)
      rescue Kiosk::Server::JwtIssuer::Error, Kiosk::AgentIdentityProviders::InvalidToken
        nil
      end

      def parse_body!
        raw = request.raw_post
        raise Errors::BadRequest, "request body must be a JSON object" if raw.nil? || raw.empty?

        parsed = JSON.parse(raw, symbolize_names: true)
        raise Errors::BadRequest, "request body must be a JSON object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise Errors.malformed_json
      end

      def respond(payload, status)
        Kiosk::Server::Headers.add_to(response.headers)
        render json: payload, status: status
      end

      # The auth plane answers the SAME RFC 9457 problem document the wire
      # does (spec §9: "the auth endpoints answer the same problem documents").
      # It moved here at the 0.4 cutover with `schema` and `pay`, in one wave —
      # not earlier, because every demo's auth flow reads a code off a 402 or a
      # 409 and half the fleet would have gone red mid-build.
      #
      # The `/oauth/*` pair is the one deliberate exception on this wire and
      # lives in its own controllers: RFC 8628 defines its own error object,
      # and answering a problem document there would break the device grant.
      def render_error(err)
        Kiosk::Server::Headers.add_to(response.headers)
        Kiosk::Server::Headers.add_cache_policy(
          response.headers, status: err.http_status
        )
        err.response_headers.each { |name, value| response.set_header(name, value) }
        if (challenge = www_authenticate_for(err))
          response.set_header("WWW-Authenticate", challenge)
        end
        render json: err.to_problem, status: err.http_status,
               content_type: Errors::PROBLEM_CONTENT_TYPE
      end

      # RFC 7235 gate header, mirroring WireController#www_authenticate_for.
      # The registration toll answers `402 pow_required`, so its response carries
      # `WWW-Authenticate: Kiosk-PoW` like the wire-verb PoW gate — the spec error
      # table states every pow_required 402 carries the header.
      def www_authenticate_for(err)
        issuer = Kiosk.configuration.issuer
        case err
        when Errors::PowRequired          then %(Kiosk-PoW realm="#{issuer}")
        when Errors::PaymentSetupRequired then %(Payment realm="#{issuer}", method="ap2")
        end
      end
    end
  end
end
