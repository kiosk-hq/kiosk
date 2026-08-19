# frozen_string_literal: true

require "kiosk/server/actions"
require "kiosk/server/errors"
require "kiosk/server/queries"

module Kiosk
  module Server
    # Rebuilds the Actions/Queries registries from the operator's
    # `Kiosk.configuration.handlers` declaration. The engine drives it from a
    # `to_prepare` block, so it runs once at boot in production and again after
    # every code reload in development.
    #
    # ── The hole this closes ─────────────────────────────────────────────
    # A {HandlerMixin} verb registers when its class BODY IS READ. Rails
    # eager-loads `app/` in production, so that happens at boot; development
    # (`config.eager_load = false`) autoloads on first reference, and nothing
    # references a handler controller — the wire reaches it through the
    # registry, and the registry is what is missing. Measured on the T-057
    # pilot before this shipped: `GET /kiosk/schema` → `queries=[] actions=[]`,
    # `POST /kiosk/query` → 404, `/.well-known/kiosk.json` →
    # `"capabilities": []` (computed from the live registry). An operator
    # following the published onboarding got a DEAD ORIGIN in development —
    # every verb missing, discovery advertising nothing.
    #
    # ── Why an operator-supplied LIST and not a convention ───────────────
    # The alternative was to glob `app/controllers/kiosk/**` and eager-load it.
    # It is rejected on neutrality: Kiosk ships a mixin, not a base class —
    # which superclass a handler has is the operator's decision (K-495) — and
    # dictating the DIRECTORY and NAMESPACE is the same imposition one level
    # up. It also cannot see handlers that live in another engine, in a
    # `packs/` tree, or anywhere else the host app puts controllers, and its
    # failure mode is the silent empty catalog above. Naming the classes is
    # one declarative line in the initializer the operator already has, it
    # composes with any layout, and it stays true when 0.4 (T-067) turns the
    # verbs into per-verb REST endpoints.
    #
    # ── Why a full REBUILD and not "declare once more" ───────────────────
    # Declaring is idempotent per name, so re-declaring would cover an ADDED or
    # EDITED verb — but not a REMOVED one: the entry from the previous
    # generation of the class would linger in the registry and the wire would
    # keep serving a verb whose method no longer exists. So each pass first
    # DROPS every entry and then re-declares from the listed classes. Since
    # T-081 an entry can only have come from the mixin — the `register` API
    # that used to install unreloadable entries alongside these is gone — so
    # the drop needs no test for what it is dropping.
    #
    # Classes are resolved BY NAME on every pass. Holding a Class object
    # across a reload pins the stale, unloaded generation — the same fork
    # {HandlerDispatch} settled for dispatch (T-053).
    module HandlerRegistrations
      class << self
        # Drops every registration and rebuilds from +handlers+ (default: the
        # configured list). Called by the engine's `to_prepare`.
        #
        # @param handlers [Array<String, Class>] class names (preferred) or classes
        # @return [Array<Class>] the handler classes registered this pass
        # @raise  [Errors::ConfigurationError] on a name that does not resolve,
        #   or a class that includes neither Kiosk::Action nor Kiosk::Query
        def reload!(handlers = Kiosk.configuration.handlers)
          clear!
          registered = Array(handlers).map { |handler| resolve(handler).kiosk_register! }
          refuse_cross_kind_collisions!
          registered
        end

        # ONE NAME, ONE KIND (§3.2). A name that is both a query and an action
        # is a path with two meanings: `GET <endpoint>/<name>` and
        # `POST <endpoint>/<name>` would reach different handlers, and the 405
        # {VerbController} answers for a method mismatch — which is the whole
        # reason that status exists on this wire — could never be right for it.
        #
        # Checked HERE and not at declaration time on purpose: the collision is
        # between two SEPARATE controller classes (a demo declares its queries
        # and its actions in different files, and must), so no single class body
        # can see it. This pass has just rebuilt both registries from a cleared
        # state, so it is the first moment the whole surface exists at once.
        def refuse_cross_kind_collisions!
          both = Actions.known & Queries.known
          return if both.empty?

          raise Errors::ConfigurationError,
            "#{both.sort.join(", ")} #{both.one? ? "is" : "are"} declared as BOTH a query and " \
            "an action. A verb name is one path segment and one kind: " \
            "GET #{Kiosk.configuration.mount_path}/<name> is a query and " \
            "POST #{Kiosk.configuration.mount_path}/<name> is an action, so a name that is " \
            "both leaves the wire with no honest answer for either. Rename one of them, or " \
            "give it a `wire_name` of its own."
        end

        # Empties both registries. Every entry in them was installed by the
        # mixin — there is no other way in — so nothing here needs to tell one
        # kind of entry from another.
        def clear!
          [Actions, Queries].each do |registry|
            # `known` returns a fresh Array, so deleting while iterating is safe.
            registry.known.each { |name| registry.unregister(name) }
          end
        end

        private

        def resolve(handler)
          name = class_name_for(handler)
          klass =
            begin
              Object.const_get(name)
            rescue NameError => e
              raise Errors::ConfigurationError,
                "Kiosk.configuration.handlers names #{name.inspect}, which does not resolve " \
                "(#{e.class}: #{e.message}). Name the handler controller exactly as the class " \
                "is defined, e.g. c.handlers = %w[Kiosk::CatalogController]."
            end

          unless klass.respond_to?(:kiosk_register!)
            raise Errors::ConfigurationError,
              "Kiosk.configuration.handlers names #{name}, which includes neither " \
              "Kiosk::Action nor Kiosk::Query. Only handler controllers belong in that list."
          end

          klass
        end

        # A Class is accepted for convenience but is immediately reduced to its
        # NAME: the object handed over in the initializer belongs to the boot
        # generation and is stale after the first reload.
        def class_name_for(handler)
          return handler.to_s unless handler.is_a?(Module)

          handler.name || raise(Errors::ConfigurationError,
            "Kiosk.configuration.handlers holds an anonymous class. Handlers are re-resolved " \
            "by name on every reload, so each one must be a named constant.")
        end
      end
    end
  end
end
