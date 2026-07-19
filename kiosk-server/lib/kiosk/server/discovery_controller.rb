# frozen_string_literal: true

# Conditionally defined — kiosk-server runs in non-Rails contexts (Rack, unit
# tests). server.rb requires this file unconditionally; the
# `if defined?(::ActionController::API)` guard below means it only defines
# DiscoveryController when ActionController::API is present. In plain Ruby the
# require is a no-op. Same pattern as WireController. Hosts mount the routes in
# their own config/routes.rb.

if defined?(::ActionController::API)
  require "kiosk/server/well_known"

  module Kiosk
    module Server
      # Discovery surface — one controller, six discovery documents, all
      # rendered from {WellKnown} (the single generator seam, so they cannot
      # drift):
      #
      #   GET /agents.txt                        → text/plain agents.txt v1.0
      #   GET /agents.json                       → application/json agents.json v1.0
      #   GET /.well-known/agent-configuration   → agent-auth discovery (kiosk-pop)
      #   GET /.well-known/kiosk.json            → the bespoke kiosk.json (derived
      #                                            alias; byte-identical to
      #                                            {WellKnown.build_json})
      #   GET /.well-known/api-catalog           → RFC 9727 linkset of the wire
      #                                            endpoints (application/linkset+json)
      #   GET /auth.md                           → agent-auth methods in the
      #                                            auth.md vocabulary
      #
      # The base URL is taken from the request (`request.base_url`), so a
      # provider that mounts these routes serves the correct origin without
      # extra config. Unauthenticated by design — discovery is public.
      class DiscoveryController < ::ActionController::API
        # GET /agents.txt — native agents.txt v1.0 envelope.
        def agents_txt
          allow_cors
          render plain: WellKnown.agents_txt(base_url: request.base_url),
                 content_type: "text/plain; charset=utf-8"
        end

        # GET /agents.json — native agents.json v1.0 companion.
        def agents_json
          allow_cors
          render json: WellKnown.agents_json(base_url: request.base_url)
        end

        # GET /.well-known/agent-configuration — agent-auth discovery.
        def agent_configuration
          render json: WellKnown.agent_configuration(base_url: request.base_url)
        end

        # GET /.well-known/kiosk.json — the bespoke discovery doc (derived
        # alias). Renders the WellKnown.build_json string verbatim so the alias
        # stays byte-identical to the canonical document.
        def kiosk_json
          render json: WellKnown.build_json(base_url: request.base_url)
        end

        # GET /.well-known/api-catalog — RFC 9727 API Catalog: a linkset of the
        # live wire endpoints (schema tagged `service-desc`) plus the discovery
        # companion. Served as `application/linkset+json` with the RFC 9727
        # profile parameter.
        def api_catalog
          allow_cors
          render json: WellKnown.api_catalog(base_url: request.base_url),
                 content_type: 'application/linkset+json; ' \
                               'profile="https://www.rfc-editor.org/info/rfc9727"'
        end

        # GET /auth.md — the provider's auth methods in the auth.md
        # vocabulary (kiosk-pop presented as anonymous-class + PoP upgrade;
        # user_claimed = the claim ceremony; link flow = Kiosk extension).
        def auth_md
          allow_cors
          render plain: WellKnown.auth_md(base_url: request.base_url),
                 content_type: "text/markdown; charset=utf-8"
        end

        private

        # agents.txt / agents.json are public discovery documents any origin's
        # agent may fetch cross-origin — the agents.txt v1.0 spec mandates
        # `Access-Control-Allow-Origin: *`.
        def allow_cors
          response.set_header("Access-Control-Allow-Origin", "*")
        end
      end
    end
  end
end
