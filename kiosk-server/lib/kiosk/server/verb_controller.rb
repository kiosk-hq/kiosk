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
    # whole invocation, and the HTTP method carries the read/write semantics
    # the retired 0.3 wire spelled out in a `name` field. Since the cutover
    # this is the ONLY way to reach an operator verb: `POST <endpoint>/query`
    # and `POST <endpoint>/run` have no route (T-074 = A).
    #
    # ── Where the routes come from, and the design delta it carries ──────
    #
    # The engine draws ONE constrained single-segment pair (`get "/:kiosk_verb"`,
    # `post "/:kiosk_verb"`) LAST in its own table and this controller resolves
    # the name against the registry AT REQUEST TIME — the same registry, read
    # the same way, that `GET <endpoint>/schema` renders its descriptors from.
    #
    # The T-067 design (§4, "Route ownership") said the OPERATOR must draw
    # these, because "the engine cannot: it would have to enumerate the registry
    # at route-draw time, before controllers are eager-loaded". That is true of
    # STATICALLY drawn routes and only of those. Resolving at request time
    # costs one registry lookup per call and buys three things: the whole
    # "declared but unrouted / routed but undeclared" bug class cannot occur
    # because there is nothing to keep in sync; the reserved plane above wins
    # by first-match, so an operator verb can never shadow `schema`, `pay`,
    # `auth`, `oauth`, `agents` or `.well-known`; and a verb added in
    # development is served on the next reload, which a routes file edited by
    # hand would NOT give (Rails reloads routes when routes files change, not
    # when a controller does). What it costs is that `rails routes` lists the
    # pair rather than the verbs — the origin's surface is read off
    # `GET <endpoint>/schema`, which is what the skill already teaches.
    #
    # ── Order of the gates, and why it is not §3.5's ─────────────────────
    #
    #   1. identity            401  IdentityResolution
    #   2. the verb exists     404  the registry (with the name-hint)
    #      …or wrong method    405  the OTHER registry, carrying `Allow:`
    #   3. the arguments       400  ArgumentDecoder + the declared input_schema
    #   4. the toll            402  PowGate, via WireController#execute_wire
    #
    # Design §3.5 lists the declared-verb check BEFORE authentication. Serving
    # it in that order would answer an UNAUTHENTICATED probe 404 for a name
    # that does not exist and 401 for one that does — enumerating the catalog
    # to anyone who can reach the origin, on a surface that is Bearer-gated
    # today (`GET <endpoint>/schema` requires an identity). Authenticating
    # first keeps that closed: every single-segment path under the mount
    # answers 401 to an unauthenticated caller, whether or not a verb by that
    # name exists.
    #
    # ── The answer ───────────────────────────────────────────────────────
    #
    # SUCCESS is the handler's rendered payload, VERBATIM (T-072 = C); ERRORS
    # are RFC 9457 problem documents. Neither is here: both seams live in
    # {WireController}, because since the cutover (T-074 = A) there is exactly
    # ONE answer shape on this wire and `GET <endpoint>/schema` and
    # `POST <endpoint>/pay` answer it too. What this class adds to its parent
    # is the name resolution, the method fork and the argument channel —
    # nothing about how a response is written.
    class VerbController < WireController
      # A verb name (design §3.2). Also the route constraint, so a path that
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
      # A name nobody registered is `404 not_found` with the registry's own
      # hint, which lists the registered names so a mistyped `listings` for
      # `browse_listings` self-corrects without a schema round-trip.
      #
      # A name registered as the OTHER KIND is `405 method_not_allowed` with
      # `Allow:` naming the method the verb does accept. The resource EXISTS —
      # answering 404 would be a lie about it, and RFC 9110 §15.5.6 already
      # has the status for exactly this. It discloses nothing: identity is
      # resolved first (401 above), and `GET <endpoint>/schema` already lists
      # every name to an authenticated caller.
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

        # Not registered as either: let the registry raise its own NotFound,
        # whose hint names what IS registered for this kind.
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

        # UNCONDITIONAL, and that is the point of this slice. `input_schema` is
        # REQUIRED on every 0.4 verb (T-073 = A) and §8.1 item 5 makes the
        # operator coerce-then-validate before the handler sees an argument, so
        # a per-verb endpoint that validated only when a flag was set would be
        # non-conformant with the flag off — and K-717's typed 400 for an
        # invalid filter value would fall out of the schema layer on some
        # origins and not others. `validate_requests` stays what it always was:
        # the opt-in PoW-SHAPE check on the 0.3 wire and the auth plane.
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
