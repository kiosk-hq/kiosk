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
    # ── The answer, and it is the whole answer (T-068 slice 2) ───────────
    #
    # SUCCESS is the handler's rendered payload, VERBATIM (T-072 = C). A
    # non-paginating query answers a bare array, a paginating one
    # `{"rows": …, "next": …}` — which is what `render_kiosk_page` already
    # produces internally — and an action answers its own object. There is no
    # `ok`, no `kind` and no wrapper: the status line carries success, and
    # `output_schema` carries the shape (slice 3 writes the 52 declarations;
    # until then the shape is discriminable from the HTTP method plus the one
    # structural rule above, which is why that rule is normative rather than a
    # convention).
    #
    # ERRORS are RFC 9457 problem documents, served as
    # `application/problem+json`, with the closed `error.code` vocabulary
    # surviving twice: as the `type` URI naming the problem and as the `code`
    # extension member an assistant branches on. See {Errors::Base#to_problem}.
    #
    # ── What this controller still leaves to the cutover ─────────────────
    #
    # `POST <endpoint>/{query,run}` keep working, unchanged, for exactly as
    # long as it takes the eight demos to migrate, and `GET <endpoint>/schema`
    # + `POST <endpoint>/pay` keep the 0.3 envelope for the same reason — the
    # demo flow scripts read `.value` off both. That is a build-time
    # intermediate inside an unreleased protocol, NOT a shipped dual stack:
    # the hard cut (T-074 = A) is the cutover slice, which deletes the first
    # pair and moves the other two onto the shape below.
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
      # has the status for exactly this. Slice 1 shipped 404-with-a-hint here
      # only because 405 was not in the closed vocabulary and adding a code is
      # spec-first (rule 1); slice 2 IS the spec change, so this is now what
      # the vocabulary says. It discloses nothing: identity is resolved first
      # (401 above), and `GET <endpoint>/schema` already lists every name to
      # an authenticated caller.
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

        if Kiosk.configuration.validate_requests
          RequestValidation.validate_arguments!(
            args, input_schema: descriptor[:input_schema], verb: name
          )
        end

        args
      end

      # ── The 0.4 answer shapes (T-072 = C) ────────────────────────────────

      # Success: the handler's payload, verbatim. {Result} still travels from
      # the {Executor} because the 0.3 endpoints next door still need it; here
      # it is unwrapped rather than serialised, and it disappears entirely at
      # the cutover.
      def render_result(result)
        render_wire_body(result.to_payload, status: result.http_status)
      end

      # Errors: an RFC 9457 problem document under its own media type. The
      # media type is the half a generic client reads — `application/json`
      # with a `title` field would be indistinguishable from any other JSON —
      # and the `code` extension member is the half an assistant reads.
      def render_wire_error(error)
        render_wire_body(
          error.to_problem,
          status:       error.http_status,
          error:        error,
          content_type: Errors::PROBLEM_CONTENT_TYPE,
        )
      end
    end
  end
end
