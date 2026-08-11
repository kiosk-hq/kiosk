# frozen_string_literal: true

# The Rails engine. It auto-injects HeadersMiddleware into the host stack
# (initializer below) and draws the ACCOUNT-BINDING surface — a host that
# `mount Kiosk::Server::Engine => Kiosk.configuration.mount_path` gets the
# full claim + link ceremony. The wire/auth/jwks/kyc/discovery routes are
# still mounted manually by hosts in their own `config/routes.rb` (see the
# demos and `e2e/fixtures/routes.rb`); folding them into this drawer is
# K-505 / T-055. The `kiosk:install` generator ships
# (lib/generators/kiosk/install).

# `rails` first: rails/engine leans on ActiveSupport core_ext that only the
# top-level entry point loads.
require "rails"
require "rails/engine"

module Kiosk
  module Server
    class Engine < ::Rails::Engine
      isolate_namespace Kiosk::Server

      # Auto-injects HeadersMiddleware into the host app's stack.
      initializer "kiosk-server.middleware" do |app|
        app.middleware.use Kiosk::Server::HeadersMiddleware
      end

      # Account-binding ceremony routes. Mount the engine at
      # the configured mount_path so the advertised URLs
      # (<endpoint>/oauth/…, <endpoint>/auth/…) resolve.
      routes do
        # Claim flow (agent-initiated; auth.md "User Claimed") — the
        # RFC 8628 wire.
        post "oauth/device_authorization", to: "oauth_device_authorization#create"
        post "oauth/token",                to: "oauth_token#create"
        get  "oauth/device/verify",        to: "device_verify#show"
        post "oauth/device/verify",        to: "device_verify#create"

        # Link flow (human-initiated; Kiosk extension) + unlink.
        post "auth/link",   to: "auth#link"
        post "auth/claim",  to: "auth#claim"
        post "auth/unlink", to: "auth#unlink"

        # «Link an assistant» page (HTML shim over the same services).
        get  "auth/assistants",        to: "assistants#show"
        post "auth/assistants/link",   to: "assistants#link"
        post "auth/assistants/unlink", to: "assistants#unlink"
      end
    end
  end
end
