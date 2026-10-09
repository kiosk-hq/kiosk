# frozen_string_literal: true

require "kiosk/server/headers"

module Kiosk
  module Server
    # Adds the Kiosk response headers to every response under the mount path.
    # Install it before `ActionDispatch::ShowExceptions` so error responses
    # are stamped too; the {Engine} does.
    class HeadersMiddleware
      def initialize(app)
        @app = app
      end

      # Read before the call: ShowExceptions rewrites PATH_INFO on an error.
      def call(env)
        kiosk = kiosk_path?(env["PATH_INFO"])
        status, headers, body = @app.call(env)
        Headers.add_to(headers) if kiosk
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
