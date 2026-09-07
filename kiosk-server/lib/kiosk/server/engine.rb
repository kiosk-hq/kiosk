# frozen_string_literal: true

# The Rails engine — THE PROTOCOL PLANE, and only the protocol plane. A host
# that puts
#
#   mount Kiosk::Server::Engine => Kiosk.configuration.mount_path
#
# in its config/routes.rb gets every path whose shape is the SPEC's rather than
# the operator's:
#
#   * the reserved wire     — GET schema (PUBLIC), POST pay
#   * the OpenAPI document  — GET openapi.json (PUBLIC)
#   * the kiosk-pop plane   — GET auth/challenge, POST auth/{register,login,revoke}
#   * JWKS                  — GET .well-known/jwks.json (under the mount)
#   * KYC attestation       — POST agents/kyc
#   * the account-binding ceremony — the RFC 8628 claim wire, the link/claim/
#     unlink endpoints, and the two HTML pages (verify, «Link an assistant»)
#   * the discovery surface — /agents.txt, /agents.json, /auth.md,
#     /.well-known/{agent-configuration,kiosk.json,api-catalog}
#
# IT DRAWS NO OPERATOR VERB, and that is the T-183 change rather than an
# omission. The operator writes one explicit route per registered verb in their
# own `config/routes/kiosk.rb`, GET for a query and POST for an action — see the
# end of the `routes do` table below for the whole argument, and
# {VerbController} for the shape of the line. The mount is drawn FIRST in that
# file, so every protocol path here wins by Rails' own first-match.
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
# Hand-drawing the same protocol routes in the host's config/routes.rb remains
# possible (e.g. for a partial surface), and nothing shipped here does it any
# more. A host that BOTH mounts and hand-draws keeps working: Rails dispatches
# the FIRST matching route, hand-drawn lines precede everything `routes.append`
# adds, and for paths under the prefix both the mount and a hand-drawn line
# reach the same shipped controller either way.
#
# A path under the mount that this engine does NOT draw falls THROUGH to the
# host's later routes — the mounted route set answers `X-Cascade: pass` and the
# host's router carries on — which is what lets an operator draw their own verbs
# below the mount at all. MEASURED on a booted demo, 2026-09-07: with the mount
# first, `GET /kiosk/nope/nope` reached a host route drawn after it.
#
# The engine also auto-injects HeadersMiddleware into the host stack
# (initializer below) — that happens on load, mounted or not, and it goes
# OUTSIDE Rails' exception renderers so a routing 404 or an unhandled 500
# under the mount carries the §3.6 headers too (K-824).
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

      # Auto-injects HeadersMiddleware into the host app's stack, OUTSIDE the
      # exception renderers (K-824).
      #
      # It used to be `app.middleware.use`, which APPENDS — the innermost
      # middleware, directly above the router. That put every response Rails
      # composes FROM AN EXCEPTION outside it, and §3.6 makes the three
      # version headers mandatory on "every response served under the
      # operator's mount path … on success and on error alike". MEASURED on a
      # booted demo: `POST /kiosk/agents/kyc` on an app that does not draw
      # that route answered a 404 with none of the three, while the same
      # origin's `POST /kiosk/auth/login` 400 carried all three — because a
      # routing 404 never returns THROUGH the appended middleware, it is
      # manufactured above it. An unhandled 500 has the same shape. Those are
      # precisely the responses a mis-versioned client is most likely to get:
      # the handshake exists so a client can decide whether it can speak to
      # this origin at all, and a 404 for a path its version expects to exist
      # is the first thing it sees.
      #
      # WHY `ActionDispatch::ShowExceptions` IS THE ANCHOR, and not another.
      # It is the OUTERMOST middleware in Rails' stack that manufactures a
      # response out of an exception: `DebugExceptions` (the development
      # diagnostic page) and `ActionableExceptions` sit INSIDE it, and the
      # `exceptions_app` that renders `public/404.html` / `public/500.html` in
      # production is called BY it. Insert immediately outside it and every
      # response the application produces — rendered by a controller, by
      # DebugExceptions, or by ShowExceptions' own exceptions_app — passes
      # back out through the stamp. Nothing between it and the router can
      # bypass it, which is the property that matters: the headers are not
      # "applied on more paths", they are applied where the stack converges.
      #
      # NOT position 0. The layers ABOVE ShowExceptions — `HostAuthorization`
      # (a 403 for a `Host` this origin does not answer to), `SSL` (the
      # http→https redirect), `Sendfile`, `Static` — answer BEFORE the
      # application is reached at all; a request rejected for naming the wrong
      # origin is not a response this operator's mount served. Staying below
      # them also keeps this middleware inside `ActionDispatch::Executor`,
      # where every other application middleware runs.
      #
      # NOT `use` with a wider rescue either: rescuing more exceptions inside
      # the engine would patch paths one at a time and still miss the routing
      # 404, which raises before any Kiosk code runs.
      #
      # A host that DELETES `ActionDispatch::ShowExceptions` from its stack
      # will fail this insert at boot with Rails' own "No such middleware"
      # error. That is the honest failure: on such a stack there is no layer
      # that renders exceptions, so there is nothing to wrap and the operator
      # has to place this middleware themselves.
      initializer "kiosk-server.middleware" do |app|
        app.middleware.insert_before ::ActionDispatch::ShowExceptions,
                                     Kiosk::Server::HeadersMiddleware
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
        # FIRST, and the order matters: {SchemaSlots} latches "this origin has
        # a data-derived slot" as declarations are read, so it has to be
        # cleared BEFORE the rebuild below re-reads them. Clearing it after
        # would throw away the latch the rebuild had just set, and an origin
        # whose only proc lives in a reloaded class would fall back to
        # boot-once caching without saying so.
        Kiosk::Server::SchemaSlots.reset!
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

      # ── The shared-spent-store warning (K-752) ────────────────────────────
      #
      # A production origin that runs MORE THAN ONE process while keeping the
      # in-process default spent store is NOT conforming (protocol.md Section
      # 15.2 + the Section 16.1 operator profile): PoW single-use then holds
      # PER WORKER, so one proof buys one request per worker.
      #
      # THIS IS A WARNING AND DELIBERATELY NOT A REFUSAL (Phil, 2026-08-19,
      # K-752 option C). A fail-closed boot was rejected on two grounds, both
      # recorded here so it is not quietly reinstated: it would turn a routine
      # `WEB_CONCURRENCY` 1→2 into an OUTAGE, and — decisively — a process-count
      # check CANNOT SEE the case that matters, because on separate machines
      # (Heroku dynos, k8s replicas) every process boots with a count of one
      # while the requirement is violated exactly as hard. So there is no
      # heuristic here at all: the condition is "the default store, in
      # production, with PoW actually switched on".
      #
      # AND THE WARNING IS NOT THE MITIGATION — the DOCUMENTATION is. Phil
      # accepted this control's weakness openly ("logs are not read, least of
      # all production warnings"), so the initializer template, the demo
      # initializers and the README carry the same WHY at greater length. The
      # reason it has to be written anywhere at all is that the failure is
      # INVISIBLE BY CONSTRUCTION: a replayed proof leaves no log line, no
      # metric and no failed request, so an operator who does nothing never
      # learns they are non-conforming.
      # The condition is a CLASS METHOD, not inline in the block, for one
      # reason: an `after_initialize` body is reachable only by booting a real
      # application in production mode, and a control whose condition cannot be
      # unit-tested is a control nobody can prove fires. Returns the message,
      # or nil when this origin has nothing to be warned about.
      #
      # @param config [Kiosk::Configuration] normally `Kiosk.configuration`
      # @param production [Boolean] normally `Rails.env.production?`
      # @return [String, nil]
      def self.shared_spent_store_warning(config:, production:)
        return nil unless production
        return nil unless config.pow_spent_store.is_a?(Kiosk::Server::PowSpentStore)
        return nil unless config.reputation_policy || config.registration_pow_count.to_i.positive?

        "[kiosk-server] pow_spent_store is the IN-PROCESS default while PoW is enabled in " \
          "production. If this origin runs more than one process — Puma workers, several " \
          "dynos or pods, or a rolling deploy that overlaps — proof single-use holds only " \
          "per process, so one proof is accepted once PER PROCESS and the toll is silently " \
          "discounted. Nothing reports it: a replayed proof produces no error, no metric " \
          "and no log line. Set a SHARED store: c.pow_spent_store = " \
          "Kiosk::Server::PowSpentStores::ActiveRecord.new — see the kiosk-server README, " \
          "\"Multi-process deployments\"."
      end

      config.after_initialize do
        message = Kiosk::Server::Engine.shared_spent_store_warning(
          config: Kiosk.configuration, production: ::Rails.env.production?,
        )
        next unless message

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

      # THE WIRE'S OWN 404/405 FOR A PATH UNDER THE MOUNT THAT NAMES NO VERB
      # THIS ORIGIN DRAWS (T-183). Appended to the HOST's route set for the one
      # property `routes` below cannot give it: it has to come AFTER the
      # operator's own explicit per-verb lines, and `routes.append` is the only
      # place that is true — the block runs when the host's set is FINALIZED.
      #
      # Drawn inside the engine's own table it would be worse than useless: a
      # mounted route set that matches answers instead of passing, so a tail
      # route there would swallow every verb path before the operator's lines
      # were ever consulted, and the explicit routes would be dead.
      #
      # WHAT IT IS NOT is the pair T-183 deleted. {VerbRefusalController} can
      # only REFUSE — 405 for a name registered as the other kind, 404
      # `verb_not_found` (with the registry's hint) for a name registered as
      # neither, and a raise for a name registered as THIS kind, which is a
      # misconfigured origin rather than a call to serve. Spec Section 8.1 and
      # Section 9 make both of those statuses MANDATORY of an operator, and an
      # unregistered name has no explicit route by construction, so without this
      # the answer would be Rails' own HTML 404 with no `code` for an assistant
      # to branch on.
      #
      # The constraint is {VerbController::NAME_SEGMENT}, the same expression
      # spec Section 8.1 gives for a verb name, so a path that could never BE a
      # verb (`/kiosk/Foo`, `/kiosk/nope/nope`) stays a routing 404 and keeps
      # carrying the Section 3.6 headers through the middleware (K-824).
      initializer "kiosk-server.verb_refusal_route" do |app|
        app.routes.append do
          next unless Kiosk::Server::Engine.mounted_in?(app.routes)

          mount_path = Kiosk.configuration.mount_path
          get  "#{mount_path}/:kiosk_verb", to: "kiosk/server/verb_refusal#show",
               constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
          post "#{mount_path}/:kiosk_verb", to: "kiosk/server/verb_refusal#create",
               constraints: { kiosk_verb: Kiosk::Server::VerbController::NAME_SEGMENT }
        end
      end

      # Everything mount-prefixed. `isolate_namespace` scopes the drawer to
      # the kiosk/server controller namespace, so "wire#schema" resolves to
      # Kiosk::Server::WireController#schema.
      routes do
        # The two RESERVED wire endpoints. They are drawn here for one reason:
        # they are the wire's OWN, not the operator's — their paths and their
        # answers are the spec's — and this table is where the protocol plane
        # lives. The operator's verbs are not here at all (see the end of this
        # table); the mount is drawn FIRST in their routes file, so every line
        # here wins over anything they write by Rails' own first-match.
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
        # (T-074 = A, the hard cut). No DEDICATED route is drawn for either
        # name and no tombstone stands in for one, so an origin serving 0.4
        # has exactly ONE wire surface and exactly one conformance surface.
        # What a caller still speaking 0.3 actually meets is
        # {VerbRefusalController}, through the tail pair the initializer above
        # appends to the host: `404 verb_not_found` as an
        # `application/problem+json` document whose `hint` names the verbs this
        # origin DOES register — the same answer any unregistered name gets,
        # which is the honest one, because `query` and `run` are now just names
        # nobody declared here (K-1112).
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
        # here, in the mounted table, so the literal `.json` path wins by
        # first-match over the appended refusal pair, which would otherwise
        # read it as the verb `openapi` in the `json` format. It needs no entry
        # in {HandlerMixin::RESERVED_NAMES}: `openapi.json` is not a legal verb
        # name (§8.1 forbids the dot), so no declaration can collide with it,
        # and an operator verb literally called `openapi` stays reachable at
        # `<endpoint>/openapi`. PUBLIC since K-804, on the same terms as
        # `schema` above. PROVISIONAL — this line and
        # `open_api{,_controller}.rb` are the whole of it.
        get "openapi.json", to: "open_api#show"

        # KYC attestation. Unconditional for the same reason as `pay`: with
        # no kyc_public_key configured the verifier rejects with the wire's
        # 403 problem document, and hosts that never advertise KYC lose nothing.
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

        # ── AND NOTHING FOR THE OPERATOR'S OWN VERBS (T-183) ──────────────
        #
        # This table ENDS here, and the absence is the design. Until T-183 it
        # closed with one constrained single-segment pair —
        # `get "/:kiosk_verb"`, `post "/:kiosk_verb"` — that matched ANY legal
        # verb name and resolved it against the registry at request time. That
        # pair is deleted. Phil, 2026-09-07: «Я НЕ СОГЛАСЕН с тем что у нас
        # должна быть какая-то магия с роутами… Вручную для каждого в routes.»
        # A mount that draws the PROTOCOL is an ordinary Rails engine; a mount
        # that draws the OPERATOR'S verbs by pattern is route magic, and it is
        # magic wherever the pattern is written — the demos spelled the same
        # pair in their own files and it was no better there.
        #
        # So the operator writes ONE EXPLICIT ROUTE PER VERB, in
        # `config/routes/kiosk.rb`, with the METHOD FOLLOWING THE KIND — GET
        # for a query, POST for an action — pinning the name with
        # `defaults: { kiosk_verb: "<name>" }`. {VerbController} is unchanged
        # and still reads the name from that parameter; what changed is who
        # supplies it. `reference/bin/check-verb-routes` derives the expected
        # list from each origin's own handler controllers and fails on a verb
        # with no route, a route with no verb, or a method that disagrees with
        # the kind.
        #
        # WHAT THE DELETION COSTS, stated rather than implied: a verb added in
        # development is no longer served on the next reload — the routes file
        # has to gain a line, which is a routes-file edit Rails does reload.
        # WHAT IT BUYS: `rails routes` lists the origin's actual wire, and the
        # method a verb answers to is a fact you can read instead of a fact the
        # dispatcher decides.
        #
        # THE RESERVED PLANE ABOVE IS UNCHANGED AND STILL WINS BY FIRST-MATCH,
        # because the operator's file draws the mount FIRST and their verbs
        # after it. That ordering is the backstop, not the control: an operator
        # verb named `schema` or `pay` is REFUSED AT DECLARATION by
        # {HandlerMixin::RESERVED_NAMES}, at boot, with the name and the reason
        # — which is where they actually meet the rule.
      end
    end
  end
end
