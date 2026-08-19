# frozen_string_literal: true

# The Rails engine — the one-line adoption surface. A host that puts
#
#   mount Kiosk::Server::Engine => Kiosk.configuration.mount_path
#
# in its config/routes.rb gets the ENTIRE shipped surface:
#
#   * the reserved wire     — GET schema (PUBLIC), POST pay
#   * the per-verb wire     — GET <query-name>, POST <action-name>
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
        # The catalog `GET <mount>/schema` serves is DERIVED from the registry
        # that line just rebuilt (T-094), so it is invalidated in the same
        # breath — a development reload that adds, renames or re-describes a
        # verb must not leave the previous document (or its digest, which is
        # the cache-busting version in every discovery link) in memory. The
        # re-derivation itself is below, in `after_initialize`, and lazily on
        # first read afterwards; this is only the drop.
        Kiosk::Server::SchemaDocument.reset!
        # And the derived OpenAPI document, which is memoized per origin off
        # the same registry (K-804). Its memo key already carries
        # {SchemaDocument.digest}, so this drop is belt-and-braces rather than
        # load-bearing — but a reload that leaves EITHER derived document in
        # memory is the bug this hook exists to prevent, and the two should be
        # dropped in the same breath they are derived from.
        Kiosk::Server::OpenApi.reset!
      end

      # THE `schema` CATALOG AND ITS DIGEST, DERIVED ONCE, AT BOOT, BY THE
      # PROCESS THAT WILL SERVE THEM (T-094, Phil 2026-08-19: «дайджест реестра
      # на буте — Да. И на тестах чтобы тоже»).
      #
      # HERE, not in each demo, and not at deploy time:
      #
      #   * IN THE GEM. One host is one demo, so per-process derivation is
      #     per-host derivation for free, and seven demos do not each carry a
      #     copy of this (the K-792 rule).
      #   * AT `after_initialize`, which Rails runs AFTER eager loading — so a
      #     production host whose handler controllers register by being READ is
      #     fully registered by now. `to_prepare` alone would derive from a
      #     half-built registry in production.
      #   * NOT PRE-GENERATED AND NOT COMMITTED. The verb roster is not the
      #     only input: a `kiosk-server` PATCH bump can change the bytes too,
      #     so the digest covers the registry, the origin config AND the gem
      #     version ({SchemaDocument.digest_inputs}). Deriving in-process means
      #     there is no second artefact on disk to drift from — drift is
      #     impossible by construction rather than caught by a guard.
      #
      # It runs in EVERY environment, test included, deliberately: an
      # initializer that skipped the test env would switch the check off in the
      # one place it catches a mistake early.
      config.after_initialize do
        Kiosk::Server::SchemaDocument.derive!
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
      # the kiosk/server controller namespace, so "wire#schema" resolves to
      # Kiosk::Server::WireController#schema.
      routes do
        # The two RESERVED wire endpoints. Every OTHER verb is served by the
        # per-verb pair at the bottom of this table, so these two are drawn
        # here for one reason only: they are the wire's own, not the
        # operator's, and drawing them first is what makes them unshadowable
        # (see the per-verb block below).
        #
        # `pay` is drawn unconditionally: a host with no payment_provider
        # answers it with the wire's own 403 ("no payment_provider
        # configured"), and discovery already drops `pay` from the advertised
        # capabilities.
        #
        # `schema` is one of the TWO routes under this mount that resolve no
        # identity (T-094, and `openapi.json` below since K-804): it answers
        # {SchemaDocument}, derived at boot, under a public cache policy. It is
        # still drawn HERE rather than beside the discovery routes because it
        # is mount-relative — it describes THIS wire, and its URL derives from
        # the discovery document's `endpoint`.
        #
        # `POST query` and `POST run` — 0.3's multiplexed pair — are GONE
        # (T-074 = A, the hard cut). Not tombstoned, not 404-with-a-hint:
        # there is no route, so an origin serving 0.4 has exactly ONE wire
        # surface and exactly one conformance surface. A caller still speaking
        # 0.3 gets a routing 404 with no Kiosk body, which is the honest
        # answer — that endpoint does not exist here.
        get  "schema", to: "wire#schema"
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

        # The DERIVED OpenAPI description (T-068 slice 4, T-071 = C). Drawn
        # here, above the per-verb pair, so the literal `.json` path wins by
        # first-match — `/:kiosk_verb(.:format)` would otherwise swallow it as
        # the verb `openapi` in the `json` format. It needs no entry in
        # {HandlerMixin::RESERVED_NAMES}: `openapi.json` is not a legal verb
        # name (§8.1 forbids the dot), so no declaration can collide with it,
        # and an operator verb literally called `openapi` stays reachable at
        # `<endpoint>/openapi`. PUBLIC since K-804, on the same terms as
        # `schema` above. PROVISIONAL — this line and
        # `open_api{,_controller}.rb` are the whole of it.
        get "openapi.json", to: "open_api#show"

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

        # ── The 0.4 per-verb wire (T-068 slice 1) ─────────────────────────
        #
        # One endpoint per registered verb — GET <endpoint>/<query-name>,
        # POST <endpoint>/<action-name> — served from ONE constrained
        # single-segment pair that resolves the name against the registry at
        # request time, exactly as `GET <endpoint>/schema` renders the
        # descriptors from it. See {VerbController} for why the engine draws
        # these rather than the operator.
        #
        # DRAWN LAST, and that placement is the design's reserved-word rule
        # (§3.2) enforced by Rails' own first-match: every route above owns
        # its first path segment, so an operator who declares a verb called
        # `schema` or `pay` cannot shadow the wire — the wire answers. A
        # declaration-time REFUSAL of such a name (so the operator learns at
        # boot rather than by their verb being unreachable) rides the
        # descriptor slice with `bin/check-kiosk-names`.
        #
        # The constraint keeps a path that cannot be a verb name out of the
        # controller entirely, so it stays a routing 404 rather than becoming
        # a 401 from the wire.
        get  "/:kiosk_verb", to: "verb#show",
             constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
        post "/:kiosk_verb", to: "verb#create",
             constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
      end
    end
  end
end
