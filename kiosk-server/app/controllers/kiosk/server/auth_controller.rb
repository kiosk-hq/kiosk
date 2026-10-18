# frozen_string_literal: true

require 'action_controller'
require 'json'

module Kiosk
  module Server
    # The spec's challenge-response auth paths (§6), drawn by the engine: challenge, register, login,
    # revoke, and the account-binding link, claim and unlink.
    class AuthController < ::ActionController::API
      # The JSON answers and RFC 9457 problem documents of the auth paths.
      module Answers
        private

        def respond(payload, status)
          Kiosk::Server::Headers.add_to(response.headers)
          render json: payload, status: status
        end

        # The same RFC 9457 problem document as the wire (§9).
        def render_error(err)
          add_problem_headers(err)
          render json: err.to_problem, status: err.http_status,
                 content_type: Errors::PROBLEM_CONTENT_TYPE
        end

        def add_problem_headers(err)
          Kiosk::Server::Headers.add_to(response.headers)
          Kiosk::Server::Headers.add_cache_policy(response.headers, status: err.http_status)
          err.response_headers.each { |name, value| response.set_header(name, value) }
          challenge = www_authenticate_for(err)
          response.set_header('WWW-Authenticate', challenge) if challenge
        end

        # RFC 7235 challenge header for the 402s, as on the wire.
        def www_authenticate_for(err)
          issuer = Kiosk.current_issuer
          case err
          when Errors::PowRequired          then %(Kiosk-PoW realm="#{issuer}")
          when Errors::PaymentSetupRequired then %(Payment realm="#{issuer}", method="ap2")
          end
        end
      end
      include Answers

      # Only the binding actions depend on this origin serving binding.
      include BindingModuleGate

      prepend_before_action :refuse_unserved_binding, only: %i[link claim unlink]

      # Unauthenticated: the nonce is worthless without the matching private key.
      def challenge
        public_key = request.query_parameters['public_key']
        raise Errors::BadRequest, 'missing public_key query parameter' if public_key.blank?

        respond(AuthChallenge.issue(public_key_pem: public_key), :ok)
      rescue Errors::Base => e
        render_error(e)
      end

      # Registers a new public key (409 if known). The optional PoW proof rides in the `Kiosk-PoW`
      # header, so the signed body stays the same on retry.
      def register
        body   = parse_body!('POST <endpoint>/auth/register')
        pow    = PowGate.proofs_from_header(request.get_header('HTTP_KIOSK_POW'))
        validate_proofs!(pow)
        result = AgentRegistration.call(public_key_pem: body.fetch(:public_key), signed: body.fetch(:signed), pow: pow)
        respond(result, :created)
      rescue KeyError => e
        render_error(Errors.missing_field(e))
      rescue Errors::Base => e
        render_error(e)
      end

      # Refresh a token for an EXISTING public key (404 if unknown → register).
      def login
        body   = parse_body!('POST <endpoint>/auth/login')
        result = AgentLogin.call(public_key_pem: body.fetch(:public_key), signed: body.fetch(:signed))
        respond(result, :ok)
      rescue KeyError => e
        render_error(Errors.missing_field(e))
      rescue Errors::Base => e
        render_error(e)
      end

      # Revokes every token of the caller's agent and returns a fresh one.
      def revoke
        identity = authenticated_agent
        raise Errors::Unauthenticated, 'agent authentication required' if identity.nil? || identity.agent_id.nil?

        Kiosk.configuration.revocation_store.revoke_all(identity.agent_id, at: Time.now.to_i)
        token = fresh_token(identity)
        respond({ access_token: token }, :ok)
      rescue Errors::Base => e
        render_error(e)
      end

      # Mints a link code for the signed-in holder; the holder's `user_idp` role becomes the bound assistant's.
      def link
        identity = authenticated_account_holder!
        result = LinkCode.mint(user_id: identity.user_id, requested_role: identity.role)
        respond({ link_code: result[:link_code], expires_in: result[:expires_in] }, :created)
      rescue Errors::Base => e
        render_error(e)
      end

      # §6.2's three fields only: `fresh` stays off the wire so a re-bind is indistinguishable (§6.3).
      CLAIM_RESPONSE_FIELDS = %i[agent_id user_id access_token].freeze

      def claim
        body   = parse_body!('POST <endpoint>/auth/claim')
        result = LinkCode.redeem(code: body.fetch(:code), public_key_pem: body.fetch(:public_key), signed: body.fetch(:signed))
        respond(result.slice(*CLAIM_RESPONSE_FIELDS), :created)
      rescue KeyError => e
        render_error(Errors.missing_field(e))
      rescue Errors::Base => e
        render_error(e)
      end

      # Deactivates one of the signed-in holder's assistant accounts; answers 204 with no body (§6.2).
      def unlink
        identity = authenticated_account_holder!
        body = parse_body!('POST <endpoint>/auth/unlink')
        AccountBinding.unlink!(agent_id: body.fetch(:agent_id), user_id: identity.user_id)
        Kiosk::Server::Headers.add_to(response.headers)
        head :no_content
      rescue KeyError => e
        render_error(Errors.missing_field(e))
      rescue Errors::Base => e
        render_error(e)
      end

      private

      def validate_proofs!(pow)
        RequestValidation.validate_proofs!(pow) if Kiosk.configuration.validate_requests && !PowGate.blank?(pow)
      end

      # Auth endpoints always mint through the bundled DefaultAgentIdp.
      def fresh_token(identity)
        AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: identity.agent_id, role: identity.role)
      end

      # The human's side of binding authenticates by the provider's session, never by an agent token.
      # A page on another origin can post a form with that cookie, but cannot send JSON without a CORS preflight.
      def authenticated_account_holder!
        identity = Kiosk.configuration.user_idp&.verify(request)
        hint = "sign in to the provider first — this endpoint authenticates via the provider's own session"
        raise Errors::Unauthenticated.new('account session required', hint:) unless identity
        raise Errors::BadRequest, 'Content-Type must be application/json' unless request.media_type == 'application/json'

        identity
      end

      # nil for a missing, invalid or revoked bearer token.
      def authenticated_agent
        IdentityResolution.agent_idp.verify(request)
      rescue Kiosk::Server::JwtIssuer::Error, Kiosk::AgentIdentityProviders::InvalidToken
        nil
      end

      # Schema-checked before any `fetch`, so a wrong-typed member is a 400 naming it (§17).
      def parse_body!(exchange)
        raw = request.raw_post
        raise Errors::BadRequest, 'request body must be a JSON object' if raw.blank?

        parsed = JSON.parse(raw, symbolize_names: true)
        raise Errors::BadRequest, 'request body must be a JSON object' unless parsed.is_a?(Hash)

        RequestValidation.validate_body!(parsed, exchange: exchange)
        parsed
      rescue JSON::ParserError
        raise Errors.malformed_json
      end
    end
  end
end
