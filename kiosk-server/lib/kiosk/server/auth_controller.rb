# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack, unit
# tests) by simply not loading this file when ActionController::API isn't
# around. Same pattern as WireController.

if defined?(::ActionController::API)
  require "json"
  require "kiosk/server/agent_registration"
  require "kiosk/server/agent_login"
  require "kiosk/server/auth_challenge"
  require "kiosk/server/errors"
  require "kiosk/server/headers"

  module Kiosk
    module Server
      # PoP auth surface (challenge-response). One controller, four actions:
      #
      #   GET  /kiosk/auth/challenge?public_key=…            → { challenge, exp }
      #   POST /kiosk/auth/register  { public_key, signed[, pow] }
      #                                → 201 { user_id, agent_id, access_token }
      #   POST /kiosk/auth/login     { public_key, signed }  → 200 { access_token }
      #   POST /kiosk/auth/revoke    (Bearer)                → 200 { access_token }
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
        def register
          body   = parse_body!
          result = AgentRegistration.call(
            public_key_pem: body.fetch(:public_key),
            signed:         body.fetch(:signed),
            pow:            body[:pow],
          )
          respond(result, :created)
        rescue KeyError => e
          render_error(Errors::BadRequest.new("missing field: #{e.message}"))
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
          render_error(Errors::BadRequest.new("missing field: #{e.message}"))
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
          token = AgentIdentityProviders::DefaultAgentIdp.new.issue(
            agent_id: identity.agent_id, role: identity.role,
          )
          respond({ access_token: token }, :ok)
        rescue Errors::Base => e
          render_error(e)
        end

        private

        # Resolve the caller's agent identity from its Bearer token. A missing,
        # invalid, or already-revoked token resolves to nil → 401.
        def authenticated_agent
          Kiosk.configuration.agent_idp&.verify(request)
        rescue Kiosk::Server::JwtIssuer::Error, Kiosk::AgentIdentityProviders::InvalidToken
          nil
        end

        def parse_body!
          raw = request.raw_post
          raise Errors::BadRequest, "request body must be a JSON object" if raw.nil? || raw.empty?

          parsed = JSON.parse(raw, symbolize_names: true)
          raise Errors::BadRequest, "request body must be a JSON object" unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError => e
          raise Errors::BadRequest, "invalid JSON body: #{e.message}"
        end

        def respond(payload, status)
          Kiosk::Server::Headers.add_to(response.headers)
          render json: payload, status: status
        end

        def render_error(err)
          Kiosk::Server::Headers.add_to(response.headers)
          render json: err.to_envelope, status: err.http_status
        end
      end
    end
  end
end
