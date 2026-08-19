# frozen_string_literal: true

# The KYC attestation surface, same shape as WireController and AuthController.

require "action_controller"
require "json"
require "kiosk/server/kyc_verifier"
require "kiosk/server/errors"
require "kiosk/server/headers"

module Kiosk
  module Server
    # POST /kiosk/agents/kyc
    #
    # Authenticates the agent (via Bearer token), verifies the submitted KYC
    # attestation JWS, and records `kyc_verified_at = now()` on the agents
    # row.
    #
    # Request body: { "kyc_jws": "<compact JWS>" }
    # Success (200): { "kyc_verified": true }
    # Failure (400/401/403): error envelope from Kiosk::Server::Errors — 400
    # for a missing/malformed/non-object JSON body or a missing kyc_jws field
    # 401 for a missing/invalid agent token, 403 for a failed KYC
    # verification.
    class KycAttestationController < ::ActionController::API
      def create
        identity = authenticate!
        body     = parse_body!
        raw_jws  = body[:kyc_jws] or raise Errors::BadRequest.new("missing field: kyc_jws")

        claims = KycVerifier.verify(raw_jws: raw_jws, identity: identity)
        mark_kyc_verified!(identity.agent_id, attributes: claims[:attributes] || {})

        Kiosk::Server::Headers.add_to(response.headers)
        render json: { kyc_verified: true, attributes: claims[:attributes] || {} }, status: :ok
      rescue Errors::Base => e
        render_error(e)
      end

      private

      # Parse the request body as a JSON object. Mirrors
      # WireController/AuthController#parse_body!: an empty body, malformed
      # JSON, or a non-object (scalar/array) body is a 400 BadRequest, never
      # a 500 — previously the bare JSON.parse ran outside the Errors::Base
      # rescue, so JSON::ParserError / TypeError (body[:kyc_jws] on an Array)
      # leaked as an unhandled 500.
      def parse_body!
        raw = request.raw_post
        raise Errors::BadRequest, "request body must be a JSON object" if raw.nil? || raw.empty?

        parsed = JSON.parse(raw, symbolize_names: true)
        raise Errors::BadRequest, "request body must be a JSON object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        raise Errors::BadRequest, "invalid JSON body: #{e.message}"
      end

      # KYC attestation is an AGENT-only surface: the effective agent IdP
      # (configured override or the bundled default; without this,
      # providers with a custom idp were locked out by a hardcoded
      # DefaultAgentIdp). No user_idp fallback — a web session must not
      # stamp an agent's kyc_verified_at.
      def authenticate!
        identity = IdentityResolution.agent_idp.verify(request)
        raise Errors::Unauthenticated.new("missing or invalid agent token") if identity.nil?

        identity
      end

      # Records verification: stamps kyc_verified_at and persists the NAMED
      # ANONYMIZED boolean attributes as jsonb. Only the booleans are stored
      # — the underlying documents never reach this layer. Written together
      # so a downstream attribute gate and the binary gate stay consistent.
      def mark_kyc_verified!(agent_id, attributes: {})
        # `lease_connection`, not `connection` (K-782, following
        # `wire_controller.rb`): `ActiveRecord::Base.connection` is
        # soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`.
        conn   = ::ActiveRecord::Base.lease_connection
        schema = Kiosk.configuration.schema
        # `$1::jsonb` carries the SAME hand-written cast, for the same reason,
        # as `executor.rb#persist_cart_mandate`'s line_items: the argument is
        # JSON *text* and the cast is what says "parse this, do not store it as
        # a json string". A jsonb column holding a string would make every
        # `->>` attribute gate downstream answer NULL for attributes that ARE
        # there. `$1` is the attesting broker's payload and `$2` is the agent id
        # off the verified token — the payload is caller-supplied, so it never
        # reaches the statement text.
        conn.exec_query(
          "UPDATE #{conn.quote_table_name("#{schema}.agents")} " \
          "SET kyc_verified_at = now(), kyc_attributes = $1::jsonb " \
          "WHERE id = $2 AND revoked_at IS NULL",
          "Kiosk KYC attestation",
          [JSON.generate(attributes), agent_id],
        )
      end

      # RFC 9457 problem document, like every other error on this wire
      # (spec §9). Moved here with the auth plane at the 0.4 cutover.
      def render_error(err)
        Kiosk::Server::Headers.add_to(response.headers)
        Kiosk::Server::Headers.add_cache_policy(
          response.headers, status: err.http_status
        )
        err.response_headers.each { |name, value| response.set_header(name, value) }
        render json: err.to_problem, status: err.http_status,
               content_type: Errors::PROBLEM_CONTENT_TYPE
      end
    end
  end
end
