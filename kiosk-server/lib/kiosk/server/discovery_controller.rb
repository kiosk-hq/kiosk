# frozen_string_literal: true

require "action_controller"
require "kiosk/server/headers"
require "kiosk/server/well_known"

module Kiosk
  module Server
    # The public discovery documents at the host root, all rendered by
    # {WellKnown} for `request.base_url`.
    class DiscoveryController < ::ActionController::API
      # Rails stamps `Vary: Accept` on a negotiated render; these documents are
      # one answer for everybody, so a shared cache must keep one copy.
      after_action :drop_vary

      def agents_txt
        allow_cors
        render plain: WellKnown.agents_txt(base_url: request.base_url),
               content_type: "text/plain; charset=utf-8"
      end

      def agents_json
        allow_cors
        short_ttl
        render json: WellKnown.agents_json(base_url: request.base_url)
      end

      def agent_configuration
        render json: WellKnown.agent_configuration(base_url: request.base_url)
      end

      def kiosk_json
        short_ttl
        render json: WellKnown.build_json(base_url: request.base_url)
      end

      def api_catalog
        allow_cors
        short_ttl
        render json: WellKnown.api_catalog(base_url: request.base_url),
               content_type: 'application/linkset+json; ' \
                             'profile="https://www.rfc-editor.org/info/rfc9727"'
      end

      def auth_md
        allow_cors
        render plain: WellKnown.auth_md(base_url: request.base_url),
               content_type: "text/markdown; charset=utf-8"
      end

      private

      # agents.txt v1.0 requires `Access-Control-Allow-Origin: *`.
      def allow_cors
        response.set_header("Access-Control-Allow-Origin", "*")
      end

      # These carry the `?v=<digest>` schema link, so they must expire soon after a deploy.
      def short_ttl
        response.set_header("Cache-Control", Headers::PUBLIC_SHORT)
      end

      def drop_vary
        response.headers.delete("Vary")
      end
    end
  end
end
