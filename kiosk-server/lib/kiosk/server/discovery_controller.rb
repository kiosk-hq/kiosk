# frozen_string_literal: true

# The discovery surface. The engine installs these routes at the HOST ROOT
# (routes.append, gated on the engine being mounted) — the agents.txt v1.0
# standard and RFC 8615 place them at the origin root, outside any mount
# prefix. Hand-drawing them in the host's config/routes.rb remains the
# escape hatch.

require "action_controller"
require "kiosk/server/headers"
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
      # NO `Vary`, ON ANY OF THE SIX (Phil, 2026-08-19: «А Vary зачем? Это
      # паблик, общедоступная инфа.»).
      #
      # None of these documents reads a request header — every one of them is
      # composed from `Kiosk.configuration` plus `request.base_url` — so there
      # is no variance to declare. But Rails declares one anyway:
      # `ActionController::Rendering#_set_vary_header` stamps `Vary: Accept` on
      # any render whose format was negotiated from a non-blank `Accept`, which
      # is what a real client sends and what `curl -H 'Accept: application/json'`
      # sends. To a shared cache that splits one document into one entry per
      # Accept string — the same damage `Vary: Authorization` would do, arriving
      # by a different route, and it would quietly undo the `public` these
      # documents are served with.
      #
      # AN `after_action`, not six `response.headers.delete` lines: the header
      # is written BY the render, so it can only be removed afterwards, and a
      # per-action copy is a line the seventh document would forget. It fires
      # for every action in this controller, which is correct — all six are
      # public. (`WireController#schema` does the same thing inline; it is one
      # public action in a class whose other actions are identity-scoped.)
      after_action :drop_vary

      # GET /agents.txt — native agents.txt v1.0 envelope.
      def agents_txt
        allow_cors
        render plain: WellKnown.agents_txt(base_url: request.base_url),
               content_type: "text/plain; charset=utf-8"
      end

      # GET /agents.json — native agents.json v1.0 companion.
      def agents_json
        allow_cors
        short_ttl
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
        short_ttl
        render json: WellKnown.build_json(base_url: request.base_url)
      end

      # GET /.well-known/api-catalog — RFC 9727 API Catalog: a linkset of the
      # live wire endpoints (schema tagged `service-desc`) plus the discovery
      # companion. Served as `application/linkset+json` with the RFC 9727
      # profile parameter.
      def api_catalog
        allow_cors
        short_ttl
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

      # THE SHORT HALF OF THE CACHE-BUSTING PAIR (T-094).
      #
      # These three documents carry the `?v=<digest>` link to
      # `<endpoint>/schema`, which is cacheable for a YEAR precisely because
      # nothing is pointed at a stale copy of it. That property is only true
      # while the POINTER expires quickly: a deploy changes the digest, and a
      # client re-reads this document within {Headers::SHORT_MAX_AGE} seconds
      # — sixty of them, since Phil weighed post-deploy staleness against
      # backend load and picked a minute — to find the new link. A long TTL
      # here would move the staleness rather than remove it, and the load it
      # would save is not saved here anyway: the bytes live behind the
      # versioned URL, which is immutable.
      #
      # `public`, because these documents are the same bytes for every caller
      # and are meant to be absorbed by a CDN — which is exactly what the
      # K-799 answer leans on when it accepts anonymous enumeration.
      def short_ttl
        response.set_header("Cache-Control", Headers::PUBLIC_SHORT)
      end

      # See the `after_action` at the top of this class.
      def drop_vary
        response.headers.delete("Vary")
      end
    end
  end
end
