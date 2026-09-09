# frozen_string_literal: true

require "action_controller"
require "kiosk/server/actions"
require "kiosk/server/argument_decoder"
require "kiosk/server/errors"
require "kiosk/server/queries"
require "kiosk/server/request_validation"
require "kiosk/server/wire_controller"

module Kiosk
  module Server
    # THE PER-VERB WIRE. One endpoint per registered verb, under the mount:
    #
    #   GET  <endpoint>/<query-name>?<args>    a query  — safe, no body
    #   POST <endpoint>/<action-name>          an action — JSON body
    #
    # so `curl -H "Authorization: Bearer …" https://…/kiosk/catalog` is the
    # whole invocation, and the HTTP method carries the read/write semantics:
    # queries are GET, actions are POST. This is the ONLY way to reach an
    # operator verb — a path that names no route matches nothing, so it is the
    # host framework's ordinary 404, with no `code` and no `hint`.
    #
    # ── Where the routes come from ───────────────────────────────────────
    #
    # THE OPERATOR DRAWS THEM, one explicit line per registered verb, in their
    # own `config/routes/kiosk.rb`:
    #
    #   get  "/kiosk/catalog",     to: "kiosk/server/verb#show",
    #        defaults: { kiosk_verb: "catalog" }
    #   post "/kiosk/place_order", to: "kiosk/server/verb#create",
    #        defaults: { kiosk_verb: "place_order" }
    #
    # The METHOD follows the KIND, which is what the protocol already says a
    # verb IS, and `defaults:` pins the name this controller reads. Nothing
    # about the request path is inferred: `params[:kiosk_verb]` is a constant
    # the route supplies.
    #
    # Hand-drawn routes buy an operator the one thing they most want out of a
    # routes file — `rails routes` lists the verbs themselves — and they cost
    # three things, each answered where it lands:
    #
    #   * declared-but-unrouted is a REAL bug class, and
    #     `reference/bin/check-verb-routes` is the check — it derives the
    #     expected list from each origin's own handler controllers and fails on
    #     a missing route, an extra route, or a method that disagrees with the
    #     kind. At runtime an unrouted verb is a 404 like any other path.
    #   * the reserved plane wins by first-match, because the operator
    #     draws `mount Kiosk::Server::Engine` FIRST and their verbs after it —
    #     and, more strongly, {HandlerMixin::RESERVED_NAMES} refuses such a
    #     declaration at boot.
    #   * a verb added in development needs a line in the routes file.
    #     Rails reloads routes when a routes file changes, so the reload is
    #     still automatic; writing the line is not.
    #
    # ── Order of the gates ───────────────────────────────────────────────
    #
    #   1. identity            401  IdentityResolution
    #   2. the verb exists     404  the registry (`verb_not_found` + name-hint)
    #      …or wrong method    405  the OTHER registry, carrying `Allow:`
    #      (both are reached only when a ROUTE hands this controller a name the
    #      registry disagrees with — an origin whose routes and declarations
    #      have drifted. A name with no route at all never gets here.)
    #   3. the arguments       400  ArgumentDecoder + the declared input_schema
    #   4. the toll            402  PowGate, via WireController#execute_wire
    #
    # IDENTITY RESOLVES FIRST because it is a precondition of every gate below
    # it. The toll is priced against the caller's reputation, the argument
    # check runs against a descriptor the caller may or may not be allowed to
    # reach, and the handler runs inside a session bound to the identity — so
    # resolving it first is the straight code path and any other order
    # re-derives it later anyway.
    #
    # It is ORDINARY GATE ORDER and not an anti-enumeration measure: the order
    # withholds nothing. `GET <endpoint>/schema` is PUBLIC and
    # `/.well-known/api-catalog` hyperlinks every verb unauthenticated, so the
    # complete list of verbs is one anonymous GET away whatever this controller
    # answers first.
    #
    # ── The answer ───────────────────────────────────────────────────────
    #
    # SUCCESS is the handler's rendered payload, VERBATIM; ERRORS are RFC 9457
    # problem documents. Neither is here: both seams live in {WireController},
    # because there is exactly ONE answer shape on this wire and
    # `GET <endpoint>/schema` and `POST <endpoint>/pay` answer it too. What this
    # class adds to its parent is the name resolution, the method fork and the
    # argument channel — nothing about how a response is written.
    class VerbController < WireController
      # A verb name (spec §8.1). Also the route constraint, so a path that
      # cannot be a verb name never reaches this controller and stays a routing
      # 404 — `/kiosk/Foo`, `/kiosk/foo-bar`, `/kiosk/9lives`.
      NAME_SEGMENT = /[a-z][a-z0-9_]*/

      # GET <endpoint>/<query-name>
      def show
        serve(:query)
      end

      # POST <endpoint>/<action-name>
      def create
        serve(:run)
      end

      private

      def serve(command)
        name       = params[:kiosk_verb].to_s
        identity   = resolve_identity!
        descriptor = descriptor_for!(command, name)
        args       = arguments_for(command, name, descriptor)

        execute_wire(command: command, args: args, identity: identity, name: name)
      end

      # The verb's published descriptor, or a refusal that says something
      # useful — and the two refusals are deliberately DIFFERENT STATUSES.
      #
      # A name nobody registered is `404 verb_not_found` with the registry's
      # `browse_listings` self-corrects without a schema round-trip. It is NOT
      # `not_found`: that code means an ARGUMENT addressed something absent
      # (spec §9.1 rule 2), and an assistant recovers from the two differently
      # — re-read the catalogue, versus tell the human it is not there.
      #
      # A name registered as the OTHER KIND is `405 method_not_allowed` with
      # `Allow:` naming the method the verb does accept. The verb EXISTS —
      # answering a 404 of either kind would be a lie about it, and RFC 9110
      # §15.5.6 already has the status for exactly this. It discloses nothing: `GET
      # <endpoint>/schema` publishes every name and its kind to ANYONE, so a
      # 405 tells a caller only what it could have read first.
      def descriptor_for!(command, name)
        registry, other = command == :query ? [Queries, Actions] : [Actions, Queries]
        return registry.describe(name) if registry.known.include?(name)

        if other.known.include?(name)
          wanted = command == :query ? "POST" : "GET"
          raise Errors::MethodNotAllowed.new(
            command == :query ? "#{name.inspect} is an action, not a query"
                              : "#{name.inspect} is a query, not an action",
            allow: wanted,
            hint:  "call #{wanted} #{Kiosk.configuration.mount_path}/#{name} instead — " \
                   "queries are GET, actions are POST.",
          )
        end

        # Not registered as either: let the registry raise its own
        # VerbNotFound, whose hint names what IS registered for this kind.
        registry.describe(name)
      end

      # A query's arguments come off the query string and have to have their
      # declared types recovered ({ArgumentDecoder}); an action's arrive as
      # JSON and already carry them. There is no third channel: a query string
      # on a POST is not read, and a body on a GET is not read.
      def arguments_for(command, name, descriptor)
        args = if command == :query
                 ArgumentDecoder.decode(request.query_string, input_schema: descriptor[:input_schema])
               else
                 parse_body!
               end

        # UNCONDITIONAL, deliberately. `input_schema` is REQUIRED on every 0.4
        # verb and §8.1 item 5 makes the operator coerce-then-validate before
        # the handler sees an argument, so a per-verb endpoint that validated
        # only when a flag was set would be non-conformant with the flag off —
        # and the typed 400 for an invalid filter value would fall out of the
        # schema layer on some origins and not others. `validate_requests`
        # covers something else: the opt-in PoW-SHAPE check on requests that
        # carry a `Kiosk-PoW` header, on the wire and on the auth plane.
        #
        # Which is why `json_schemer` is a REAL runtime dependency of this gem
        # since 0.4 (see the gemspec): an origin that cannot load a validator
        # cannot serve a conformant wire. It is still required lazily, and a
        # vendored checkout without it still gets {Errors::ConfigurationError}
        # naming the gem rather than a LoadError at boot.
        RequestValidation.validate_arguments!(
          args, input_schema: descriptor[:input_schema], verb: name
        )

        args
      end

    end
  end
end
