# frozen_string_literal: true

require 'action_controller'
require 'json'

module Kiosk
  module Server
    # The Kiosk auth paths that no OAuth standard covers (§5.7, §6), drawn by the
    # engine: the key rotation, and the account-binding link, claim and unlink.
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
          when Errors::PaymentSetupRequired then %(Kiosk-Payment-Setup realm="#{issuer}")
          end
        end
      end
      include Answers

      # The auth toll's proofs: the `Kiosk-PoW` header, schema-checked, or nil.
      module Proofs
        private

        def proofs
          header = request.get_header('HTTP_KIOSK_POW')
          pow    = PowGate.proofs_from_header(header)
          RequestValidation.validate_proofs!(pow) if Kiosk.configuration.validate_requests && pow
          pow
        end
      end
      include Proofs

      # Only the binding actions depend on this origin serving binding.
      include BindingModuleGate

      prepend_before_action :refuse_unserved_binding, only: %i[link claim unlink]

      # A refused client assertion is a 401, with the hint that says what to fix.
      rescue_from(ClientAssertion::Refused) { |e| render_error(e.to_problem) }

      # Puts a new key on a registered client; both keys sign (§5.7). Answers the client information.
      def rotate
        body   = parse_body!('POST <endpoint>/auth/rotate')
        client = AgentRotation.call(type: body.fetch(:client_assertion_type), assertion: body.fetch(:client_assertion),
                                    new_assertion: body.fetch(:new_client_assertion), jwks: body.fetch(:jwks))
        respond(client.information, :ok)
      rescue KeyError => e
        render_error(Errors.missing_field(e))
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

      # Binds the client to the human who minted the code; answers 204. The
      # optional toll's proofs ride in the `Kiosk-PoW` header.
      def claim
        body = parse_body!('POST <endpoint>/auth/claim')
        LinkCode.redeem(code: body.fetch(:code), assertion_type: body.fetch(:client_assertion_type),
                        assertion: body.fetch(:client_assertion), pow: proofs)
        Kiosk::Server::Headers.add_to(response.headers)
        head :no_content
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

      # The human's side of binding authenticates by the provider's session, never by an agent token.
      # A page on another origin can post a form with that cookie, but cannot send JSON without a CORS preflight.
      def authenticated_account_holder!
        identity = Kiosk.configuration.user_idp&.verify(request)
        hint = "sign in to the provider first — this endpoint authenticates via the provider's own session"
        raise Errors::Unauthenticated.new('account session required', hint:) unless identity
        raise Errors::BadRequest, 'Content-Type must be application/json' unless request.media_type == 'application/json'

        identity
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
