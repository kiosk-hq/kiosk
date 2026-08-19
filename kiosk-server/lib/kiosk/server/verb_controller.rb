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
    # THE 0.4 PER-VERB WIRE (T-068 slice 1). One endpoint per registered verb,
    # under the same mount the 0.3 wire uses:
    #
    #   GET  <endpoint>/<query-name>?<args>    a query  — safe, no body
    #   POST <endpoint>/<action-name>          an action — JSON body
    #
    # so `curl -H "Authorization: Bearer …" https://…/kiosk/catalog` is the
    # whole invocation, and the HTTP method carries the read/write semantics
    # the 0.3 wire spelled out in a `name` field.
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
    # ── What this controller does NOT do yet ─────────────────────────────
    #
    # The response is still the 0.3 envelope (`{ok, kind, rows|value, next?}`)
    # and errors are still the 0.3 error envelope: retiring the envelope and
    # moving errors to RFC 9457 `application/problem+json` is the NEXT slice
    # (T-072 = C), and doing it here would have made this slice a wire break
    # rather than an addition. `POST <endpoint>/query` and `POST
    # <endpoint>/run` therefore keep working, unchanged, for exactly as long
    # as it takes the demos to migrate — the hard cut (T-074 = A) is the
    # cutover slice, not this one.
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

      # The verb's published descriptor, or a 404 that says something useful.
      #
      # Two 404s, deliberately different: a name nobody registered gets the
      # registry's own hint (which lists the registered names, so a mistyped
      # `listings` for `browse_listings` self-corrects without a schema
      # round-trip), while a name registered as the OTHER KIND gets the method
      # it should have been called with. The second one is new to this wire —
      # under 0.3 a query and an action were different endpoints with the same
      # shape, and confusing them was a bare "unknown query".
      def descriptor_for!(command, name)
        registry, other = command == :query ? [Queries, Actions] : [Actions, Queries]
        return registry.describe(name) if registry.known.include?(name)

        if other.known.include?(name)
          raise Errors::NotFound.new(
            command == :query ? "#{name.inspect} is an action, not a query"
                              : "#{name.inspect} is a query, not an action",
            hint: "call #{command == :query ? "POST" : "GET"} " \
                  "#{Kiosk.configuration.mount_path}/#{name} instead — " \
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

        if Kiosk.configuration.validate_requests
          RequestValidation.validate_arguments!(
            args, input_schema: descriptor[:input_schema], verb: name
          )
        end

        args
      end
    end
  end
end
