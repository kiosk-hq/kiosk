# frozen_string_literal: true

# kiosk-server — Rails engine (when in a Rails host) + pure-Ruby pieces
# (well-known doc builder, headers, schema-migration SQL) that don't need
# a host. See https://kiosk.tech and design spec §3, §6.7.

require "kiosk"
require "kiosk/rls"

require "kiosk/server/version"
require "kiosk/server/configuration_extension"
require "kiosk/server/headers"
require "kiosk/server/headers_middleware"
require "kiosk/server/well_known"
require "kiosk/server/schema_definitions"

# Optional Rails engine — only defines itself if Rails::Engine is loaded.
require "kiosk/server/engine"

module Kiosk
  module Server
    # No top-level methods yet. The pieces are:
    #
    #   - {Kiosk::Server::WellKnown}        — builds /.well-known/kiosk.json
    #   - {Kiosk::Server::Headers}          — composes the three response headers
    #   - {Kiosk::Server::HeadersMiddleware}— Rack middleware that injects them
    #   - {Kiosk::Server::SchemaDefinitions}— SQL for migrations 001-004
    #   - {Kiosk::Server::Engine}           — Rails engine (if Rails is loaded)
    #
    # Controllers (`/kiosk/exec`, OAuth, agent registration) + the
    # Executor land in a follow-up release.
  end
end
