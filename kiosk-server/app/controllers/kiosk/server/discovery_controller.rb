# frozen_string_literal: true

require 'action_controller'

module Kiosk
  module Server
    # The public discovery documents at the host root, all rendered by
    # {WellKnown} for `request.base_url`.
    class DiscoveryController < ::ActionController::API
      # Rails stamps `Vary: Accept` on a negotiated render; these documents are
      # one answer for everybody, so a shared cache must keep one copy.
      after_action :drop_vary
      before_action :allow_cors

      def agents_txt
        render plain: WellKnown.agents_txt(base_url: request.base_url),
               content_type: 'text/plain; charset=utf-8'
      end

      def agents_json
        short_ttl
        render json: WellKnown.agents_json(base_url: request.base_url)
      end

      def oauth_authorization_server
        render json: WellKnown.oauth_authorization_server(base_url: request.base_url)
      end

      def oauth_protected_resource
        render json: WellKnown.oauth_protected_resource(base_url: request.base_url)
      end

      def agent_skills_index
        render_or_not_found WellKnown.agent_skills_index
      end

      def ard
        short_ttl
        render json: WellKnown.ard(base_url: request.base_url)
      end

      def kiosk_json
        short_ttl
        render json: WellKnown.build_json(base_url: request.base_url)
      end

      def api_catalog
        short_ttl
        # RFC 9727 §2: a HEAD request finds the catalog by this header.
        response.set_header('Link', %(<#{request.base_url}/.well-known/api-catalog>; rel="api-catalog"))
        render json: WellKnown.api_catalog(base_url: request.base_url),
               content_type: 'application/linkset+json; ' \
                             'profile="https://www.rfc-editor.org/info/rfc9727"'
      end

      def auth_md
        render plain: WellKnown.auth_md(base_url: request.base_url),
               content_type: 'text/markdown; charset=utf-8'
      end

      private

      def render_or_not_found(document)
        document ? render(json: document) : head(:not_found)
      end

      # agents.txt v1.0 and AI Catalog require `Access-Control-Allow-Origin: *`.
      # Every document here answers it, so a page on any origin can read it.
      def allow_cors
        response.set_header('Access-Control-Allow-Origin', '*')
      end

      # These carry the `?v=<digest>` schema link, so they must expire soon after a deploy.
      def short_ttl
        response.set_header('Cache-Control', Headers::PUBLIC_SHORT)
      end

      def drop_vary
        response.headers.delete('Vary')
      end
    end
  end
end
