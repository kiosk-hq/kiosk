# frozen_string_literal: true

require "action_controller"
require "kiosk/server/actions"
require "kiosk/server/queries"
require "kiosk/server/handler_dispatch"

module Kiosk
  module Server
    # Implementation behind `include Kiosk::Action` / `include Kiosk::Query`.
    # Operators never name this module — they include one of the two public
    # ones, which is the whole of the contract:
    #
    #   Kiosk ships a MIXIN, not a base class. Which superclass a handler
    #   controller has is the operator's decision (K-495: "не наследуем.
    #   Наследование решает оператор"), so nothing here inherits, and the
    #   only requirement is that the including class BE a controller —
    #   dispatch goes through `Controller.action(…)`.
    #
    # ── The macros ───────────────────────────────────────────────────────
    # Each macro records a declaration; the NEXT `def` claims all pending ones
    # and becomes a wire verb (`method_added`, the classic). A method defined
    # with no pending declarations is NOT a verb — the macros are the opt-in, so
    # a controller's helper methods stay invisible to the wire.
    #
    #   description    — semantics ONLY: what this verb does, how, and what it
    #                    returns IN MEANING. Never a field list, a type, a
    #                    required marker, or a param name (ADR-0023 / K-500).
    #   input_schema   — JSON Schema for the params. THE input contract: every
    #                    name, type, enum and range lives here.
    #   output_schema  — JSON Schema for what comes back, so an assistant knows
    #                    the result shape without a call-and-observe probe.
    #   example_params — a params object an assistant can copy verbatim.
    #   example_row    — a worked example of the result.
    #   wire_name      — OPTIONAL. The name agents call it by, when it cannot be
    #                    the method name (a Ruby keyword, or a name that would
    #                    collide with a controller method).
    #
    # ── What is NOT here ─────────────────────────────────────────────────
    # `params:` (the free-text name → hint hash) is retired by ADR-0023 and has
    # no macro: a hint is either a constraint (schema) or a meaning
    # (description), and there is no third thing. It survives on the registry's
    # `register` call only because the demos still pass it until T-057.
    module HandlerMixin
      KINDS = %i[action query].freeze

      # Installs the mixin. Called from Kiosk::Action.included / Kiosk::Query.included.
      def self.install(base, kind:)
        raise ArgumentError, "unknown handler kind #{kind.inspect}" unless KINDS.include?(kind)

        unless base.is_a?(Class) && base <= ::ActionController::Metal
          raise ArgumentError,
            "include Kiosk::#{kind.to_s.capitalize} into a controller class — Kiosk dispatches " \
            "handlers through Controller.action(…), which needs an ActionController subclass. " \
            "Pick the base class yourself (ApplicationController, ActionController::API, …); " \
            "Kiosk does not impose one."
        end

        installed = base.respond_to?(:kiosk_kind) ? base.kiosk_kind : nil
        if installed && installed != kind
          raise ArgumentError,
            "#{base} already includes Kiosk::#{installed.to_s.capitalize}. A controller declares " \
            "queries OR actions, never both — the verb it is reached by is a property of the " \
            "class. Split it in two."
        end
        return if installed == kind

        base.instance_variable_set(:@kiosk_kind, kind)
        base.extend(ClassMethods)
        base.include(InstanceMethods)

        # The wire request is authenticated at WireController by bearer token /
        # proof-of-possession — never by a cookie session — and this sub-dispatch
        # is server-internal, so it can never present a CSRF token. Without this,
        # every real app (Rails sets protect_from_forgery on ActionController::Base
        # by default) would answer every action with InvalidAuthenticityToken.
        # ActionController::API has no forgery protection to skip.
        base.skip_forgery_protection if base.respond_to?(:skip_forgery_protection)

        # Belt and braces: if an operator ALSO draws a route to a handler
        # controller, that route must not become an unauthenticated, CSRF-exempt
        # way in. Only a dispatch through the Kiosk seam sets the marker.
        base.before_action(:kiosk_require_wire_dispatch!) if base.respond_to?(:before_action)
      end

      # Registry for a kind. Not a constant map: `Actions`/`Queries` must be
      # resolved lazily so this file can be required before them.
      def self.registry_for(kind)
        kind == :action ? Actions : Queries
      end

      module ClassMethods
        # :action or :query, inherited — so an operator's own base class can
        # carry the include and its subclasses declare verbs, which is the
        # shape the generator will scaffold (T-056).
        def kiosk_kind
          return @kiosk_kind if defined?(@kiosk_kind) && @kiosk_kind

          superclass.respond_to?(:kiosk_kind) ? superclass.kiosk_kind : nil
        end

        # ── the macros ─────────────────────────────────────────────────
        def description(text)
          kiosk_pending[:description] = text
        end

        def input_schema(schema = nil, **kwargs)
          kiosk_pending[:input_schema] = schema || kwargs
        end

        def output_schema(schema = nil, **kwargs)
          kiosk_pending[:output_schema] = schema || kwargs
        end

        def example_params(example = nil, **kwargs)
          kiosk_pending[:example_params] = example || kwargs
        end

        def example_row(example = nil, **kwargs)
          kiosk_pending[:example_row] = example || kwargs
        end

        def wire_name(name)
          kiosk_pending[:wire_name] = name.to_s
        end

        # ── binding ────────────────────────────────────────────────────

        # Binds the pending declarations to the method just defined. `super`
        # first: AbstractController::Base hooks method_added too (to invalidate
        # its action_methods cache) and must keep running.
        def method_added(method_name)
          super
          pending = @kiosk_pending
          return if pending.nil? || pending.empty?

          @kiosk_pending = nil
          kiosk_declare(method_name, pending)
        end

        # wire name → declaration, for the verbs declared on THIS class.
        def kiosk_declarations
          @kiosk_declarations ||= {}
        end

        # Re-registers this class's verbs in the process-wide registry. Runs
        # automatically as the class body is read; call it directly only to
        # restore registrations after a test reset.
        def kiosk_register!
          kiosk_declarations.each_value { |declaration| kiosk_register_one(declaration) }
          self
        end

        private

        def kiosk_pending
          @kiosk_pending ||= {}
        end

        def kiosk_declare(method_name, pending)
          kind = kiosk_kind
          if kind.nil?
            raise ArgumentError,
              "#{self} declared a Kiosk verb but includes neither Kiosk::Action nor Kiosk::Query"
          end

          declaration = pending.merge(
            kind:        kind,
            method_name: method_name.to_s,
            wire_name:   (pending[:wire_name] || method_name).to_s,
          )
          kiosk_declarations[declaration[:wire_name]] = declaration
          kiosk_register_one(declaration)
        end

        def kiosk_register_one(declaration)
          handler = HandlerDispatch.new(
            controller:  self,
            method_name: declaration[:method_name],
            wire_name:   declaration[:wire_name],
            kind:        declaration[:kind],
          )
          HandlerMixin.registry_for(declaration[:kind]).register(
            declaration[:wire_name], handler,
            description:    declaration[:description],
            input_schema:   declaration[:input_schema],
            output_schema:  declaration[:output_schema],
            example_params: declaration[:example_params],
            example_row:    declaration[:example_row],
          )
        end
      end

      # Handler-side helpers. All private, so none of them can be mistaken for
      # a controller action.
      module InstanceMethods
        private

        # The {Kiosk::Identity} the wire resolved for this request — the acting
        # assistant-account (and agent, when an assistant is calling). nil when
        # the handler was reached outside a wire request (an RLS journey test).
        # The four GUCs are already set on the connection either way, so SQL-side
        # scoping does not depend on this.
        def kiosk_identity
          request.env[HandlerDispatch::IDENTITY_KEY]
        end

        # The wire name this dispatch arrived under — differs from the method
        # name only when the class declared `wire_name`.
        def kiosk_wire_name
          request.env[HandlerDispatch::DISPATCH_KEY]
        end

        # Answer a query with ONE PAGE of rows plus an opaque cursor the
        # assistant echoes back in `cursor` to fetch the next one. A nil
        # next_cursor means this is the last page. See {Kiosk::Server::Cursor}
        # for the offset-cursor helper.
        def render_kiosk_page(rows, next_cursor: nil)
          request.env[HandlerDispatch::PAGE_KEY] = true
          render json: { rows: rows, next_cursor: next_cursor }
        end

        # Handler controllers are reachable ONLY through the Kiosk wire, which
        # is where authentication, the PoW gate and the GUC-scoped transaction
        # live. A route drawn straight at one would bypass all three, so it 404s
        # — the same answer the operator's app gives for any other path it does
        # not serve.
        def kiosk_require_wire_dispatch!
          return if request.env.key?(HandlerDispatch::DISPATCH_KEY)

          render json: {
            ok:    false,
            error: {
              code:    "not_found",
              message: "Kiosk handlers are reachable through the Kiosk wire only",
              hint:    "call POST #{Kiosk.configuration.mount_path}/query or " \
                       "#{Kiosk.configuration.mount_path}/run with the verb's name",
            },
          }, status: :not_found
        end
      end
    end
  end
end
