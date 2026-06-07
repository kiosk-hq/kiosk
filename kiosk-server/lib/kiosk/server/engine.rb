# frozen_string_literal: true

# Rails engine skeleton. Conditionally defined — `kiosk-server` runs
# happily in non-Rails contexts (e.g. plain Rack app or unit tests) by
# simply not loading this file via the autoload graph.
#
# The full engine wiring (routes, generators, middleware mounting) lands
# in a follow-up session along with the controllers it would mount.
# Until then this file is a placeholder declaration so the gem can be
# loaded inside a Rails app without surprise.

if defined?(::Rails::Engine)
  module Kiosk
    module Server
      class Engine < ::Rails::Engine
        isolate_namespace Kiosk::Server

        # Auto-injects HeadersMiddleware into the host app's stack.
        initializer "kiosk-server.middleware" do |app|
          app.middleware.use Kiosk::Server::HeadersMiddleware
        end

        # Routes drawer lands when controllers exist. For now: empty.
        # routes do; end
      end
    end
  end
end
