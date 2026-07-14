# frozen_string_literal: true

# Rails engine skeleton. Conditionally defined — `kiosk-server` runs
# happily in non-Rails contexts (e.g. plain Rack app or unit tests): the
# file is always required (server.rb loads it unconditionally), but the
# `if defined?(::Rails::Engine)` guard below means it only defines the
# Engine class when Rails is present. In plain Ruby the require is a no-op.
#
# The wire/auth/jwks/kyc controllers have shipped; the engine auto-injects
# HeadersMiddleware into the host stack (initializer below). Route wiring is
# NOT drawn by the engine yet — host apps mount the controllers manually in
# their own `config/routes.rb` (see the demos and `e2e/fixtures/routes.rb`).
# An automatic routes drawer remains deferred; the `kiosk:install`
# generator ships (lib/generators/kiosk/install).

if defined?(::Rails::Engine)
  module Kiosk
    module Server
      class Engine < ::Rails::Engine
        isolate_namespace Kiosk::Server

        # Auto-injects HeadersMiddleware into the host app's stack.
        initializer "kiosk-server.middleware" do |app|
          app.middleware.use Kiosk::Server::HeadersMiddleware
        end

        # No engine-drawn routes yet — hosts mount the (shipped) controllers
        # manually in their own config/routes.rb. Auto-drawer deferred.
        # routes do; end
      end
    end
  end
end
