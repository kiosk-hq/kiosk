# frozen_string_literal: true

require "action_controller"
require "action_dispatch"
require "kiosk/server/actions"
require "kiosk/server/errors"
require "kiosk/server/failure_log"
require "kiosk/server/queries"
require "kiosk/server/handler_dispatch"

module Kiosk
  module Server
    # Implementation behind `include Kiosk::Handler`. Operators never name this
    # module — they include the public one, which is the whole of the contract:
    #
    #   Kiosk ships a MIXIN, not a base class. Which superclass a handler
    #   controller has is the operator's decision, so nothing here inherits,
    #   and the only requirement is that the including class BE a controller —
    #   dispatch goes through `Controller.action(…)`.
    #
    # ── The macros ───────────────────────────────────────────────────────
    # Each macro records a declaration; the NEXT `def` claims all pending ones
    # and becomes a wire verb (`method_added`, the classic). A method defined
    # with no pending declarations is NOT a verb — the macros are the opt-in, so
    # a controller's helper methods stay invisible to the wire.
    #
    #   reach          — OPTIONAL, and the DEFAULT is the strong case. Whose rows
    #                    this verb may touch: `:principal` (default — only the
    #                    calling principal's own, which is spec §7.2's absolute
    #                    requirement), `:published`, `:consented` or `:role`.
    #                    See the long note below.
    #   kind           — REQUIRED. `:query` (reached by `GET <mount>/<name>`) or
    #                    `:action` (`POST <mount>/<name>`). THE single source of
    #                    truth for which verb reaches this handler, and it is a
    #                    property of the DECLARATION: one controller may declare
    #                    both, in any order. It is required rather than
    #                    defaulted because either default silently assigns an
    #                    HTTP method — a write behind `GET` is the expensive
    #                    direction of that mistake.
    #   description    — semantics ONLY: what this verb does, how, and what it
    #                    returns IN MEANING. Never a field list, a type, a
    #                    required marker, or a param name.
    #   input_schema   — REQUIRED. JSON Schema for the params. THE input
    #                    contract: every name, type, enum and range lives here.
    #   output_schema  — REQUIRED. JSON Schema for what comes back, so an
    #                    assistant knows the result shape without a
    #                    call-and-observe probe. Both are required of every verb
    #                    by protocol.md Section 8.3 and by
    #                    `schema-descriptor.schema.json`, and a declaration
    #                    missing either RAISES here, at class-body load.
    #   example_params — OPTIONAL. A params object an assistant can copy verbatim.
    #   example_row    — OPTIONAL. A worked example of the result.
    #   wire_name      — OPTIONAL. The name agents call it by, when it cannot be
    #                    the method name (a Ruby keyword, or a name that would
    #                    collide with a controller method).
    #
    # ── `reach` — WHOSE ROWS A VERB MAY TOUCH ────────────────────────────
    # Spec §7.2's DEFAULT is absolute: every read is scoped to the authenticated
    # `user_id` and another `user_id`'s rows are never readable. But a
    # legitimate operator domain can need wider reach — philslist's open board,
    # tudu's shared lists, stylish's owner calendar are three shipped examples —
    # because data separation is the operator's business logic, and Kiosk's job
    # is to SUPPLY the means (an identity resolved before dispatch, the four
    # GUCs, a principal that is never a wire input), not to dictate the model.
    #
    # So the default is unchanged and stays absolute, and any DEPARTURE from it
    # is declared — explicitly, per verb, and published on the wire — rather than
    # being an implicit consequence of how a handler happens to be written:
    #
    #   :principal  DEFAULT. This verb touches only the calling principal's own
    #               rows, or rows that belong to no principal at all (a catalogue,
    #               a price list). Declare nothing and you have declared this.
    #   :published  The operator PUBLISHES these owner-carrying rows to every
    #               principal, by intent — a classifieds board. Costly by design:
    #               §7.2 forbids putting an account's login identifier in such a
    #               row.
    #   :consented  A principal SHARED them, and the authorising artefact is one
    #               the operator can point at — tudu's single-use invite becomes
    #               a membership, and the membership is what permits the read.
    #               The spec calls this the stronger of the two sharing claims.
    #   :role       The reach depends on the caller's operator-ASSIGNED `role`
    #               claim — stylish's salon owner sees the whole book, everyone
    #               else sees their own bookings. A role is never client-requested
    #               (§5.4), which is what keeps this from being a self-service
    #               escalation.
    #
    # DECLARING A REACH DOES NOT MAKE IT CORRECT — it makes it REVIEWABLE. An
    # undeclared cross-principal read is a defect whether or not the operator
    # meant it; that asymmetry is the whole point, because "unless the operator
    # intends otherwise" would have swallowed §7.2 whole (every leak is intended
    # from the leaker's side).
    #
    # ── A SLOT MAY BE A PROC, for a schema derived from DATA ──────────────
    # Any part of `input_schema`, `output_schema`, `example_params` or
    # `example_row` may be a zero-arity proc:
    #
    #   input_schema type: "object", additionalProperties: false,
    #                properties: {
    #                  category_slug: { type: "string",
    #                                   enum: -> { Category.pluck(:slug) } },
    #                }
    #
    # Use it when the constraint IS a fact about the operator's rows. Do NOT
    # write the plain call — `enum: Category.pluck(:slug)` runs while the class
    # body is read, which is `db:create`, `db:migrate` and `assets:precompile`
    # too, and it captures a list that then goes stale for the life of the
    # process. The proc is called when the descriptor is SERVED, memoized, and
    # re-resolved on a short lifetime, so adding a category publishes itself
    # without a restart and without a deploy. {Kiosk::Server::SchemaSlots}
    # carries the mechanism and the concurrency argument. `description`,
    # `kind`, `reach` and `wire_name` are NOT resolvable: the first is prose
    # semantics, two are routing facts fixed when the route is drawn, and
    # `reach` is a security claim about the verb — a claim computed from the
    # operator's rows could change under a caller between the catalog it read
    # and the call it made.
    #
    # ── Errors ───────────────────────────────────────────────────────────
    # Rails' idiom, end to end: `render json:, status:` answers the wire with
    # the status' lone code; a body naming an explicit vocabulary `error.code`
    # (a 403 `rls_denied`, a SPECIFIC 402) — the HANDLER-side spelling, since
    # what TRAVELS is the flat top-level `code` — travels verbatim; and
    # a raise Rails knows a status for — `params.require`, RecordNotFound,
    # anything in `config.action_dispatch.rescue_responses` — is mapped by
    # the one `rescue_from` this include installs
    # ({InstanceMethods#kiosk_rescue_to_wire}). No Kiosk error classes in
    # handler code; the wire-only gate classes remain raisable.
    #
    # ── What is NOT here ─────────────────────────────────────────────────
    # There is no `params:` macro — no free-text name → hint hash: a hint is
    # either a constraint (schema) or a meaning (description), and there is no
    # third thing. Spec §8.3 carries no such key either, so a descriptor this
    # registry builds does not have a slot for one.
    #
    # ── The read-only guarantee this mixin does NOT make ─────────────────
    # One mixin serves both kinds, so "this class provably cannot write" is not
    # readable off the include. That is deliberate: the same namespace
    # legitimately both answers queries and performs actions, and forcing a
    # split at class granularity would fragment a cohesive resource for a
    # reason the domain does not have.
    #
    # The property is DEFERRED, not lost. If it is ever wanted it returns as an
    # OPT-IN controller-level macro — `read_only!` / `query_only!`, refusing an
    # `action` declaration in the class body and saying so at boot — which is
    # strictly better: it STATES the guarantee instead of implying it from which
    # module was included, and only the operators who want it pay for it. That
    # macro is deliberately not built here; this paragraph is where it goes.
    module HandlerMixin
      KINDS = %i[action query].freeze

      # The four reaches of spec §7.2, in the order the spec names them. The
      # first is the DEFAULT and is what a declaration that says nothing means:
      # an operator gets the absolute per-principal scoping by writing nothing at
      # all, and pays a line only to depart from it.
      REACHES = %i[principal published consented role].freeze

      # What an undeclared `reach` means. Not a fallback for a missing
      # declaration the way `kind` refuses to have one: `kind` silently assigns
      # an HTTP method and either default is a mistake, while every possible
      # default here except the strictest would silently widen a verb.
      DEFAULT_REACH = :principal

      # ── spec §8.1 / §8.3, enforced where the mistake is made ─────────────
      #
      # A verb name is ONE path segment on the wire, so the three rules the
      # spec states about names are properties a DECLARATION either has or does
      # not, and all three are checked here — at class-body load, naming the
      # class and the method — rather than discovered later as a verb that is
      # merely unreachable.
      #
      # `NAME_PATTERN` is §8.1's `^[a-z][a-z0-9_]*$`, the same expression the
      # engine's route constraint uses; a name that fails it could never be
      # routed at all.
      NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/

      # `RESERVED_NAMES` are the first path segments the ENGINE itself draws
      # under the mount, and this list is the PRIMARY control rather than a
      # courtesy. Rails' first-match still protects those paths — the
      # operator draws the mount FIRST in config/routes/kiosk.rb and their own
      # verb routes after it, so a verb called `schema` is shadowed, never
      # shadowing — but that ordering is now a property of a file somebody
      # writes rather than of a table the engine controls end to end, and being
      # silently unreachable was always a worse answer than a boot-time refusal
      # that says which name is taken and why. THIS is where an operator meets
      # the rule: an `ArgumentError` as the class body loads, naming the class,
      # the method and the taken name. `.well-known` is drawn too and is
      # deliberately absent: it cannot match NAME_PATTERN, so no declaration can
      # collide with it.
      #
      # `bin/check-kiosk-names` holds this list against the engine's own route
      # table, so a route added there without a name added here fails the build
      # instead of quietly re-opening a shadowed name.
      #
      # `query` and `run` are NOT on this list, and that is the check earning
      # its keep in the other direction: the engine draws no such segments, so
      # reserving them would be reserving nothing — a boot-time refusal for a
      # name that is, in fact, free. An operator may declare a verb called
      # `query` or `run`; none does, and one that did would be served at
      # `<endpoint>/query` like any other.
      RESERVED_NAMES = %w[agents auth events oauth pay schema].freeze

      # The descriptor fields REQUIRED on every verb. Both are
      # contracts a caller acts on — `input_schema` is what the wire coerces
      # and validates arguments against (§8.1 item 5),
      # `output_schema` is the ONLY machine-readable statement of the answer
      # shape now that the envelope's `kind` is gone (§8.2) — so a verb that
      # omits either publishes an incomplete contract, and the engine refuses
      # to register one rather than serving it.
      REQUIRED_DECLARATIONS = %i[input_schema output_schema].freeze

      # Installs the mixin. Called from Kiosk::Handler.included.
      def self.install(base)
        unless base.is_a?(Class) && base <= ::ActionController::Metal
          raise ArgumentError,
            "include Kiosk::Handler into a controller class — Kiosk dispatches " \
            "handlers through Controller.action(…), which needs an ActionController subclass. " \
            "Pick the base class yourself (ApplicationController, ActionController::API, …); " \
            "Kiosk does not impose one."
        end

        # Idempotent: an operator's own base class may carry the include and its
        # subclasses declare verbs, so the same install can arrive twice down one
        # ancestry. Re-running it would re-register the filters below.
        return if base.respond_to?(:kiosk_declarations)

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

        # THE ONE Rails-raise → wire-code seam. Registered at include time, so
        # any `rescue_from` the operator declares later — below the include, or
        # in a subclass — matches first and wins; this is the floor, not a
        # ceiling. See
        # {InstanceMethods#kiosk_rescue_to_wire} for what it maps.
        base.rescue_from(StandardError, with: :kiosk_rescue_to_wire) if base.respond_to?(:rescue_from)
      end

      # Registry for a kind. Not a constant map: `Actions`/`Queries` must be
      # resolved lazily so this file can be required before them.
      def self.registry_for(kind)
        kind == :action ? Actions : Queries
      end

      # The scope a `topic` block is evaluated in, and its whole job is to keep
      # a topic's `reach` and `description` OUT of `kiosk_pending`.
      #
      # `kiosk_pending` belongs to verbs: `method_added` drains it onto the next
      # method defined in the class. So a topic declared the way a verb is —
      # `topic :todo` followed by bare `reach` / `description` — would attach
      # those values to whatever verb happened to be defined after it, silently
      # and with no error anywhere. The block is what closes that, and it is why
      # this macro reads differently from its neighbours.
      class TopicDeclaration
        attr_reader :reach_value, :description_value, :payload_schema_value,
                    :subject_reachable_value

        def reach(value)
          unless REACHES.include?(value)
            raise ArgumentError,
              "a topic declared `reach #{value.inspect}`, which is not a Kiosk reach. " \
              "It is :principal (the default — only the calling principal's own events), " \
              ":published (the operator publishes to everyone, by intent), :consented (a " \
              "principal shared the subject, and the operator can point at the artefact " \
              "that says so) or :role (the reach follows the caller's operator-assigned " \
              "role claim)."
          end

          @reach_value = value
        end

        def description(text) = @description_value = text

        def payload_schema(schema = nil, **kwargs) = @payload_schema_value = schema || kwargs

        # `(subject, identity) -> Boolean`, re-run on every subscribe AND on the
        # re-authorisation timer — never reading {CurrentRequest}, which is
        # fiber-local and does not reach a socket callback.
        def subject_reachable(callable) = @subject_reachable_value = callable

        def validate!(owner:, name:)
          missing = Events::REQUIRED.reject { |field| public_send(:"#{field}_value") }
          return if missing.empty?

          raise ArgumentError,
            "#{owner} declared `topic #{name.inspect}` without " \
            "#{missing.join(" and ")}. A topic carries `description` for semantics and " \
            "`payload_schema` for shape; a subscriber with neither has to receive a " \
            "message to find out what it is."
        end
      end

      module ClassMethods
        # ── the macros ─────────────────────────────────────────────────

        # :query or :action — which HTTP method reaches the next-defined
        # method. Per DECLARATION, so a controller may carry both.
        def kind(value)
          unless KINDS.include?(value)
            raise ArgumentError,
              "#{self} declared `kind #{value.inspect}`, which is not a Kiosk verb kind. " \
              "It is :query (reached by GET #{Kiosk.configuration.mount_path}/<name>) or " \
              ":action (POST #{Kiosk.configuration.mount_path}/<name>)."
          end

          kiosk_pending[:kind] = value
        end

        # Whose rows this verb may touch (spec §7.2). Omit it and the
        # verb is `:principal` — the absolute case, and the one most operators
        # want. Declared per DECLARATION, like `kind`, so one controller may hold
        # an owner-scoped verb and a published one.
        def reach(value)
          unless REACHES.include?(value)
            raise ArgumentError,
              "#{self} declared `reach #{value.inspect}`, which is not a Kiosk verb reach. " \
              "It is :principal (the default — only the calling principal's own rows, or rows " \
              "that belong to no principal), :published (the operator publishes owner-carrying " \
              "rows to everyone, by intent), :consented (a principal shared them, and the " \
              "operator can point at the artefact that says so) or :role (the reach follows the " \
              "caller's operator-assigned role claim). A verb that touches nobody else's rows " \
              "declares nothing at all."
          end

          kiosk_pending[:reach] = value
        end

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

        # Declare an EVENT TOPIC — a standing feed a subscriber holds, rather
        # than a verb a caller invokes.
        #
        #   topic :todo do
        #     reach :consented
        #     description "A todo on a list you can reach was added, completed " \
        #                 "or reopened — by another member's assistant or by a " \
        #                 "human in the browser."
        #     payload_schema type: "object", additionalProperties: false,
        #                    properties: { todo_id: { type: "string" },
        #                                  done:    { type: "boolean" } },
        #                    required: %w[todo_id done]
        #     subject_reachable ->(subject, identity) { Membership.reachable?(subject, identity) }
        #   end
        #
        # IT TAKES A BLOCK, unlike every macro above it, and the difference is
        # load-bearing rather than stylistic — see {HandlerMixin::TopicDeclaration}.
        #
        # The name is validated HERE, at declaration time, against the same two
        # rules a verb name meets: it is a path-legal wire name, and it is not a
        # segment the engine itself draws. A topic is not routed, but it IS a
        # `topic` argument on the subscribe frame and a name in the published
        # catalogue, so the same vocabulary applies and a clash with a reserved
        # segment would be a name an operator can declare and nothing can reach.
        def topic(name, &block)
          name = name.to_s

          unless name.match?(NAME_PATTERN)
            raise ArgumentError,
              "#{self} declared `topic #{name.inspect}`, which is not a legal Kiosk name. " \
              "A topic name is a wire name: #{NAME_PATTERN.inspect}."
          end

          if RESERVED_NAMES.include?(name)
            raise ArgumentError,
              "#{self} declared `topic #{name.inspect}`, but that name is reserved by the " \
              "engine itself: #{RESERVED_NAMES.join(", ")}. Give the topic a name of its own."
          end

          declaration = TopicDeclaration.new
          declaration.instance_eval(&block) if block
          declaration.validate!(owner: self, name: name)

          # HELD ON THE CLASS, REGISTERED BY {#kiosk_register!} — the same two
          # steps a verb takes, and for the reason a verb takes them. Declaring
          # STRAIGHT into the process-wide registry looked simpler and was
          # wrong: a class body is read again on every Zeitwerk reload and
          # again by an eager load after a lazy one, and the second read met
          # its own first and raised «already declared on this origin» at boot.
          # Worse in the other direction — a topic DELETED from a controller
          # would have stayed in the catalogue until the process restarted,
          # because nothing re-derives a registry that is only ever added to.
          # The engine's `to_prepare` drops all three registries and rebuilds
          # them from `c.handlers`; topics ride that same rebuild now.
          kiosk_topic_declarations[name] = {
            name: name,
            reach: declaration.reach_value || :principal,
            description: declaration.description_value,
            payload_schema: declaration.payload_schema_value,
            subject_reachable: declaration.subject_reachable_value,
          }
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

        # wire name → declaration, for the verbs declared on THIS class. ONE
        # entry per name is the invariant, not an implementation detail: a name
        # is one path segment and one kind, so a second declaration under the
        # same name is refused rather than stored (see
        # {#kiosk_refuse_bad_declaration!}).
        def kiosk_declarations
          @kiosk_declarations ||= {}
        end

        # This class's topic declarations, by wire name. Same shape and same
        # lifecycle as {#kiosk_declarations}: filled as the class body is read,
        # drained into the process-wide registry by {#kiosk_register!}.
        def kiosk_topic_declarations
          @kiosk_topic_declarations ||= {}
        end

        # Re-registers this class's verbs AND topics in the process-wide
        # registries. Runs automatically as the class body is read; call it
        # directly only to restore registrations after a test reset.
        def kiosk_register!
          kiosk_declarations.each_value { |declaration| kiosk_register_one(declaration) }
          kiosk_topic_declarations.each_value { |declaration| Events.register(**declaration) }
          self
        end

        private

        def kiosk_pending
          @kiosk_pending ||= {}
        end

        def kiosk_declare(method_name, pending)
          declaration = pending.merge(
            method_name: method_name.to_s,
            wire_name:   (pending[:wire_name] || method_name).to_s,
            reach:       pending[:reach] || HandlerMixin::DEFAULT_REACH,
          )
          kiosk_refuse_bad_declaration!(declaration)
          kiosk_declarations[declaration[:wire_name]] = declaration
          kiosk_register_one(declaration)
        end

        # The name rules of spec §8.1 / §8.3 and the required descriptor
        # fields, raised at DECLARATION time so the operator meets them at boot
        # with the class and the method in hand.
        def kiosk_refuse_bad_declaration!(declaration)
          name = declaration[:wire_name]
          where = "#{self}##{declaration[:method_name]}"

          if declaration[:kind].nil?
            raise ArgumentError,
              "#{where} declares the Kiosk verb #{name.inspect} without a `kind`. Every " \
              "declaration says which verb reaches it: `kind :query` is served at " \
              "GET #{Kiosk.configuration.mount_path}/#{name}, `kind :action` at " \
              "POST #{Kiosk.configuration.mount_path}/#{name}. One controller may declare " \
              "both — the kind belongs to the declaration, not to the class — so there is " \
              "no default to fall back on."
          end

          # ONE NAME, ONE DECLARATION, for the half a single class body can see.
          # The cross-class half is {HandlerRegistrations.refuse_cross_kind_collisions!},
          # which is the first moment the whole surface exists at once; this is
          # the same rule caught earlier, where the operator has both methods in
          # hand.
          #
          # A code reload does NOT come through here: the engine's `to_prepare`
          # calls {ClassMethods#kiosk_register!}, which re-registers from the
          # declarations already stored, and a reloaded class body is read on a
          # NEW class object whose `kiosk_declarations` starts empty. So a clash
          # at this point is always two declarations in one generation of one
          # class body — an operator mistake with no legitimate reading.
          clash = kiosk_declarations[name]
          if clash && clash[:kind] != declaration[:kind]
            raise ArgumentError,
              "#{where} declares #{name.inspect} as a#{declaration[:kind] == :action ? "n" : ""} " \
              "#{declaration[:kind]}, but ##{clash[:method_name]} on this class already " \
              "declares it as a#{clash[:kind] == :action ? "n" : ""} #{clash[:kind]}. A verb " \
              "name is one path segment and one kind: " \
              "GET #{Kiosk.configuration.mount_path}/#{name} and " \
              "POST #{Kiosk.configuration.mount_path}/#{name} cannot reach different handlers. " \
              "Rename one, or give it a `wire_name` of its own."
          elsif clash
            raise ArgumentError,
              "#{where} declares the Kiosk verb #{name.inspect}, which ##{clash[:method_name]} " \
              "on this class already declares. A verb name is ONE path segment reaching ONE " \
              "method: storing the second would replace the first, " \
              "#{Kiosk.configuration.mount_path}/#{name} would reach " \
              "##{declaration[:method_name]}, and ##{clash[:method_name]} would be off the wire " \
              "with nothing to say so. Rename one of the methods, or give one of them a " \
              "`wire_name` of its own."
          end

          unless HandlerMixin::NAME_PATTERN.match?(name)
            raise ArgumentError,
              "#{where} declares the Kiosk verb #{name.inspect}, which is not a legal verb " \
              "name. A verb is ONE path segment matching #{HandlerMixin::NAME_PATTERN.source} " \
              "(spec §8.1) — lower case, starting with a letter, digits and underscores after " \
              "that. Rename the method, or give it a legal `wire_name`."
          end

          if HandlerMixin::RESERVED_NAMES.include?(name)
            raise ArgumentError,
              "#{where} declares the Kiosk verb #{name.inspect}, which is RESERVED: the engine " \
              "draws #{Kiosk.configuration.mount_path}/#{name} itself, and the mount is drawn " \
              "before your own routes, so that route wins by first-match — the verb would never " \
              "be reached. Reserved: " \
              "#{HandlerMixin::RESERVED_NAMES.join(", ")}. Give it a `wire_name` of its own."
          end

          missing = HandlerMixin::REQUIRED_DECLARATIONS.reject { |key| declaration.key?(key) }
          return if missing.empty?

          raise ArgumentError,
            "#{where} declares the Kiosk verb #{name.inspect} without #{missing.join(" and ")}. " \
            "Both are REQUIRED on every verb: `input_schema` is the contract the wire " \
            "coerces and validates arguments against, and `output_schema` is the only " \
            "machine-readable statement of what the call returns now that the response " \
            "envelope is gone. A verb that takes nothing still declares " \
            "`input_schema type: \"object\", additionalProperties: false, properties: {}, " \
            "required: []`."
        end

        def kiosk_register_one(declaration)
          handler = HandlerDispatch.new(
            controller:  self,
            method_name: declaration[:method_name],
            wire_name:   declaration[:wire_name],
            kind:        declaration[:kind],
          )
          HandlerMixin.registry_for(declaration[:kind]).declare(
            declaration[:wire_name], handler,
            reach:          declaration[:reach],
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
        #
        # `total` is how many rows MATCH the query across all pages, not how
        # many this page carries. It becomes the `X-Total-Count` response
        # header. Pass it only if you know it: nil omits the header, which is
        # the honest answer for a keyset cursor over an uncounted set, and is
        # why this is not defaulted to `rows.length` — on a TRUNCATED page that
        # would state the page size as the total.
        #
        # WHAT THE ASSISTANT SEES. Not this hash: the body is the bare
        # `rows` array, exactly like a non-paginating query's, and the two page
        # facts leave as response headers — `Link: <…?cursor=…>; rel="next"`
        # (RFC 8288) and `X-Total-Count`. The hash below is the INTERNAL
        # carrier between a Rails-dispatched handler and {HandlerDispatch},
        # which rebuilds the {Kiosk::Server::Page} from it.
        def render_kiosk_page(rows, next_cursor: nil, total: nil)
          request.env[HandlerDispatch::PAGE_KEY] = true
          render json: { rows: rows, next_cursor: next_cursor, total: total }
        end

        # The one place a Rails-native raise becomes a wire code. Three kinds
        # of raise reach it:
        #
        #   * a Kiosk wire error ({Errors::Base}) — re-raised untouched: it
        #     already names its code, and the Kiosk seam renders it.
        #   * an exception Rails knows a status for — looked up in Rails' OWN
        #     table (`config.action_dispatch.rescue_responses`, the registry
        #     the host app already extends for its libraries: Pundit's
        #     NotAuthorizedError → :forbidden and so on; Active Record adds
        #     RecordNotFound → :not_found when it boots). The status' lone
        #     wire code ({Errors::STATUS_CODES}) is rendered as the ordinary
        #     error envelope — so `params.require` answers `bad_request` and
        #     a model lookup miss answers `not_found` with no Kiosk classes
        #     in the handler. 402 and 500 have no lone code and are never
        #     guessed.
        #   * anything else — re-raised, so the {Executor} wraps it as
        #     `action_failed` exactly as it always has.
        #
        # THE EXCEPTION'S OWN SENTENCE DOES NOT TRAVEL. This branch exists
        # for exceptions the operator did NOT author — «no Kiosk classes in the
        # handler» is its whole purpose — so its message is always some
        # library's wording: rendered, a `params.require(:sku)` handler would
        # put actionpack's «param is missing or the value is empty or invalid:
        # sku» on a 400 problem document. The wire gets
        # {Errors.rescued_wire}'s sentence and hint for the code this
        # seam decided; the class, the message and the backtrace go to the
        # operator's log ({FailureLog}), the way {Executor}'s two 500 paths
        # already send theirs. An operator who means to SPEAK to the agent has
        # two routes that never reach this line — render the envelope, or raise
        # an {Errors::Base} — and both are pinned by the suite.
        def kiosk_rescue_to_wire(exception)
          raise exception if exception.is_a?(Kiosk::Server::Errors::Base)

          status = ::ActionDispatch::ExceptionWrapper.rescue_responses[exception.class.name]
          code   = Kiosk::Server::Errors::STATUS_CODES[::Rack::Utils.status_code(status)]
          raise exception if code.nil?

          Kiosk::Server::FailureLog.report(
            "verb #{kiosk_wire_name.inspect} answered #{code} for #{exception.class}", exception
          )

          # Hand the exception to {HandlerDispatch} so the wire error it builds
          # for this render carries it as `cause`. Operator-side only:
          # it reaches the audit sink and nothing else, because a `cause` is not
          # part of any problem document.
          request.env[HandlerDispatch::RESCUED_KEY] = exception

          render json: {
            ok:    false,
            error: Kiosk::Server::Errors.rescued_wire(code, verb: kiosk_wire_name),
          }, status: Kiosk::Server::Errors::CODES.fetch(code)
        end

        # Handler controllers are reachable ONLY through the Kiosk wire, which
        # is where authentication, the PoW gate and the GUC-scoped transaction
        # live. A route drawn straight at one would bypass all three, so it 404s
        # — the same answer the operator's app gives for any other path it does
        # not serve.
        #
        # THE BODY IS A FLAT RFC 9457 PROBLEM DOCUMENT, built by
        # {Errors::VerbNotFound} itself so it cannot drift from the one the wire
        # renders. `verb_not_found` and not `not_found`: the
        # caller dialed a path that is not a wire verb path at all, so nothing
        # was ADDRESSED, and the hint below tells it to call the verb's own
        # route -- which is precisely the `verb_not_found` recovery. This render is CLIENT-FACING and nothing re-wraps it: the
        # guard returns early under sub-dispatch, so it only ever fires on a
        # route the operator drew straight at a handler controller, where there
        # is a machine on the other end and no human page in sight.
        #
        # NOT the same call as {#kiosk_rescue_to_wire} above, which keeps the
        # nested shape ON PURPOSE: that one is the internal sub-dispatch
        # protocol between a handler and {HandlerDispatch}, whose `error.code`
        # vocabulary and extra envelope fields the Executor decodes and re-wraps
        # before anything reaches a client. Flattening it would change the seam,
        # not the wire.
        def kiosk_require_wire_dispatch!
          return if request.env.key?(HandlerDispatch::DISPATCH_KEY)

          problem = Kiosk::Server::Errors::VerbNotFound.new(
            "Kiosk handlers are reachable through the Kiosk wire only",
            hint: "call the verb's own route — " \
                  "GET #{Kiosk.configuration.mount_path}/<query-name> or " \
                  "POST #{Kiosk.configuration.mount_path}/<action-name>",
          ).to_problem

          render json:         problem,
                 status:       :not_found,
                 content_type: Kiosk::Server::Errors::PROBLEM_CONTENT_TYPE
        end
      end
    end
  end
end
