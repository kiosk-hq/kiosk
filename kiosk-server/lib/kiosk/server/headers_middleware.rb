# frozen_string_literal: true

require "kiosk/server/headers"

module Kiosk
  module Server
    # Rack middleware that injects the three Kiosk response headers
    # (`Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client`)
    # on responses whose path starts with the configured mount path.
    #
    # Mount in a Rails app:
    #
    #   # config/application.rb
    #   config.middleware.use Kiosk::Server::HeadersMiddleware
    #
    # Or in a Rack app:
    #
    #   use Kiosk::Server::HeadersMiddleware
    class HeadersMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        status, headers, body = @app.call(env)
        if kiosk_path?(env["PATH_INFO"])
          Headers.add_to(headers)
        end
        [status, headers, body]
      end

      private

      def kiosk_path?(path)
        return false if path.nil? || path.empty?

        mount = Kiosk.configuration.mount_path
        path == mount || path.start_with?("#{mount}/")
      end
    end
  end
end
