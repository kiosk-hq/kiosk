# frozen_string_literal: true

# The Rails engine — the one-line adoption surface. A host that puts
#
#   mount Kiosk::Server::Engine => Kiosk.configuration.mount_path
#
# in its config/routes.rb gets the ENTIRE shipped surface:
#
#   * the wire verbs        — GET schema, POST query / run / pay
#   * the kiosk-pop plane   — GET auth/challenge, POST auth/{register,login,revoke}
#   * JWKS                  — GET .well-known/jwks.json (under the mount)
#   * KYC attestation       — POST agents/kyc
#   * the account-binding ceremony — the RFC 8628 claim wire, the link/claim/
#     unlink endpoints, and the two HTML pages (verify, «Link an assistant»)
#   * the discovery surface — /agents.txt, /agents.json, /auth.md,
#     /.well-known/{agent-configuration,kiosk.json,api-catalog}
#
# The discovery routes are ROOT-relative — the agents.txt v1.0 standard and
# RFC 8615 (.well-known) place them at the origin root, so they cannot live
# under a mount prefix. They are installed into the HOST's route set by the
# `kiosk-server.root_discovery_routes` initializer below via
# `Rails.application.routes.append`, GATED on the engine actually being
# mounted: merely loading the gem must not add routes to a host that chose
# not to mount. (`isolate_namespace` scopes CONSTANTS, not URLs, so an
# engine installing root paths on the host is fine.)
#
# Hand-drawing the same routes in the host's config/routes.rb remains the
# documented escape hatch (e.g. for a partial surface). A host that BOTH
# mounts and hand-draws keeps working: Rails dispatches the FIRST matching
# route, hand-drawn lines precede everything `routes.append` adds, and for
# paths under the prefix both the mount and a hand-drawn line reach the
# same shipped controller either way.
#
# The engine also auto-injects HeadersMiddleware into the host stack
# (initializer below) — that happens on load, mounted or not.
#
# The `kiosk:install` generator ships in lib/generators/kiosk/install.

# `rails` first: rails/engine leans on ActiveSupport core_ext that only the
# top-level entry point loads.
require "rails"
require "rails/engine"

module Kiosk
  module Server
    class Engine < ::Rails::Engine
      isolate_namespace Kiosk::Server

      # True when this engine is mounted anywhere in +route_set+. Used by the
      # root-discovery initializer below to keep the gem inert-by-default;
      # public so a host can ask the same question (e.g. in a smoke test).
      # Journey stores a mounted rack endpoint wrapped in a Constraints
      # object whose #app is whatever `mount` was given — this engine CLASS
      # in the documented one-liner, or its instance.
      def self.mounted_in?(route_set)
        route_set.routes.any? do |route|
          app = route.app
          app.respond_to?(:app) && (app.app == self || app.app.is_a?(self))
        end
      end

      # Auto-injects HeadersMiddleware into the host app's stack.
      initializer "kiosk-server.middleware" do |app|
        app.middleware.use Kiosk::Server::HeadersMiddleware
      end

      # THE VERBS ARE REGISTERED BY THE ENGINE, not by the operator — the hole
      # the T-057 pilot measured (empty catalog, 404 wire, empty capabilities).
      # `to_prepare` runs once at boot in production and again after every code
      # reload in development, which is exactly the cadence a registry built
      # from reloadable classes needs: the operator NAMES their handler
      # controllers (`c.handlers`) and never writes reload plumbing.
      # {HandlerRegistrations} rebuilds — drop, then re-declare — so a verb
      # deleted from a controller leaves the catalog and stops being served,
      # which a re-declare-only pass would miss. Runs for every host: with no
      # handlers declared it empties the registries. Note the order Rails fixes
      # — this runs BEFORE `eager_load!` — so in production a handler left out
      # of the list is still registered afterwards, by being read; it is
      # development, and every reload, where the omission shows.
      config.to_prepare do
        Kiosk::Server::HandlerRegistrations.reload!
      end

      # One honest line when this origin has NO verbs at all — the state that
      # answers `GET <mount>/schema` with an empty catalog and advertises
      # `"capabilities": []`. Emitted from `after_initialize`, which runs AFTER
      # eager loading, so a production app whose handlers register by being
      # eager-loaded is not falsely accused.
      config.after_initialize do
        next unless Kiosk.configuration.handlers.empty?
        next unless Kiosk::Server::Actions.known.empty? && Kiosk::Server::Queries.known.empty?

        message =
          "[kiosk-server] no queries or actions are registered: GET " \
          "#{Kiosk.configuration.mount_path}/schema will answer with an empty catalog and the " \
          "discovery documents will advertise no capabilities. Name your handler controllers " \
          "in the initializer — Kiosk.configure { |c| c.handlers = %w[Kiosk::CatalogController] }."
        ::Rails.logger ? ::Rails.logger.warn(message) : warn(message)
      end

      # Root-relative discovery surface. `routes.append` blocks run when the
      # host's route set is FINALIZED — after config/routes.rb has been
      # drawn — so the mount (and any hand-drawn duplicate, which then wins
      # by first-match) is already visible when the gate runs. Re-evaluated
      # on every dev-mode routes reload.
      initializer "kiosk-server.root_discovery_routes" do |app|
        app.routes.append do
          next unless Kiosk::Server::Engine.mounted_in?(app.routes)

          # agents.txt / agents.json are ROOT-served per the agents.txt v1.0
          # standard; the .well-known trio per RFC 8615; auth.md is the
          # root-level human/agent auth handbook agents.txt points at.
          get "/agents.txt",  to: "kiosk/server/discovery#agents_txt"
          get "/agents.json", to: "kiosk/server/discovery#agents_json"
          get "/auth.md",     to: "kiosk/server/discovery#auth_md"
          get "/.well-known/agent-configuration", to: "kiosk/server/discovery#agent_configuration"
          get "/.well-known/kiosk.json",          to: "kiosk/server/discovery#kiosk_json"
          get "/.well-known/api-catalog",         to: "kiosk/server/discovery#api_catalog"
        end
      end

      # Everything mount-prefixed. `isolate_namespace` scopes the drawer to
      # the kiosk/server controller namespace, so "wire#run" resolves to
      # Kiosk::Server::WireController#run.
      routes do
        # Wire verbs. `pay` is drawn unconditionally: a host with no
        # payment_provider answers it with the wire's own 403 envelope
        # ("no payment_provider configured"), and discovery already drops
        # `pay` from the advertised capabilities.
        get  "schema", to: "wire#schema"
        post "query",  to: "wire#query"
        post "run",    to: "wire#run"
        post "pay",    to: "wire#pay"

        # kiosk-pop auth plane (challenge-response proof-of-possession).
        get  "auth/challenge", to: "auth#challenge"
        post "auth/register",  to: "auth#register"
        post "auth/login",     to: "auth#login"
        post "auth/revoke",    to: "auth#revoke"

        # JWKS — under the MOUNT (RFC 8615 applies to the origin root; the
        # wire pins this one under <endpoint> and auth.md advertises it
        # there).
        get ".well-known/jwks.json", to: "jwks#show"

        # KYC attestation. Unconditional for the same reason as `pay`: with
        # no kyc_public_key configured the verifier rejects with the wire's
        # 403 envelope, and hosts that never advertise KYC lose nothing.
        post "agents/kyc", to: "kyc_attestation#create"

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

        # «Link an assistant» page (HTML shim over the same services). The
        # page's own forms post to link/update/unlink, so all four routes
        # ship together.
        get  "auth/assistants",        to: "assistants#show"
        post "auth/assistants/link",   to: "assistants#link"
        post "auth/assistants/update", to: "assistants#update"
        post "auth/assistants/unlink", to: "assistants#unlink"
      end
    end
  end
end
