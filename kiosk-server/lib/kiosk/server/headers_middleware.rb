# frozen_string_literal: true

require "kiosk/server/headers"

module Kiosk
  module Server
    # Rack middleware that injects the three Kiosk response headers
    # (`Kiosk-Server-Version`, `Kiosk-API-Version`, `Kiosk-Min-Client`)
    # on responses whose path starts with the configured mount path.
    #
    # In a Rails app the {Engine} installs it for you, and WHERE it installs
    # it is load-bearing (K-824): it goes OUTSIDE
    # `ActionDispatch::ShowExceptions`, so a response Rails composes from an
    # exception — a routing 404 under the mount, an unhandled 500 — is stamped
    # too. Installing it by hand means the same position:
    #
    #   # config/application.rb
    #   config.middleware.insert_before ActionDispatch::ShowExceptions,
    #                                   Kiosk::Server::HeadersMiddleware
    #
    # `config.middleware.use` APPENDS — innermost, below the exception
    # renderers — which is the placement that left those responses bare and is
    # why this comment spells the position out rather than the class name.
    #
    # In a plain Rack app, wrap whatever renders your errors:
    #
    #   use Kiosk::Server::HeadersMiddleware
    #
    # NOT EVERY PATH — only the mount. The guard below is what keeps an
    # operator's own routes out of it: the engine is mounted INSIDE somebody
    # else's application, and stamping Kiosk headers on that application's
    # pages would be this gem talking about surfaces it does not serve.
    class HeadersMiddleware
      def initialize(app)
        @app = app
      end

      # THE PATH IS READ ON THE WAY IN, NOT ON THE WAY OUT (K-824), and that is
      # not a style choice. `ActionDispatch::ShowExceptions#render_exception`
      # REWRITES `env["PATH_INFO"]` to `/404` or `/500` before handing the
      # request to the exceptions app, and never puts it back — so a middleware
      # that asks "was this a Kiosk path?" AFTER calling down the stack is
      # asking about a path the caller never sent, and every unhandled 500
      # under the mount answers "no". Which request this is was decided before
      # the app ran; that is when it is recorded.
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
