# frozen_string_literal: true

require "kiosk/server/verb_controller"

module Kiosk
  module Server
    # THE WIRE'S OWN REFUSAL FOR A PATH THAT NAMES NO VERB THIS ORIGIN SERVES.
    #
    # It answers `404 verb_not_found` and `405 method_not_allowed` — the two
    # statuses spec Section 8.1 and Section 9 make MANDATORY of an operator —
    # and it CANNOT do anything else. Read that literally: there is no code path
    # here that reaches a handler, renders a payload or touches the executor. If
    # the name resolves to a verb of the kind the request asked for, this
    # controller RAISES, because that state is a misconfigured origin rather
    # than a call to serve.
    #
    # ── Why it exists, and why it is not the route magic T-183 deleted ──────
    #
    # Until T-183 the engine drew ONE constrained pair — `get "/:kiosk_verb"`,
    # `post "/:kiosk_verb"` — LAST in its own table, and {VerbController}
    # resolved the name against the registry at request time. That pair SERVED
    # every registered verb, which is the route magic Phil rejected: an
    # operator could not read their own wire off their own routes file.
    #
    # Deleting it leaves a hole the spec does not allow to stay open. An
    # unregistered NAME has, by construction, no explicit route, so without a
    # tail route it answers Rails' own HTML routing 404: no `code`, no `hint`
    # naming the verbs that DO exist, and an AI assistant that is told to branch
    # on `code` has nothing to branch on. The same hole swallows the `405`: a
    # query called with POST simply matches no route.
    #
    # So this controller is drawn — by the engine, into the HOST's route set,
    # AFTER the operator's own routes (see the `kiosk-server.verb_refusal_route`
    # initializer in {Engine}) — behind the same single-segment constraint the
    # deleted pair used. What makes it a different thing is not where it is
    # drawn but WHAT IT CAN DO:
    #
    #   * a name registered as the OTHER kind → 405 with `Allow`
    #   * a name registered as NEITHER        → 404 `verb_not_found` + the hint
    #   * a name registered as THIS kind      → RAISES. The operator declared a
    #     verb and drew no route for it; serving it here would silently restore
    #     the magic, so it fails loudly instead and names the line to add.
    #     `reference/bin/check-verb-routes` makes that state unreachable in a
    #     build, which is why the raise is a backstop and not a user-facing
    #     answer.
    #
    # ── Order of the gates ─────────────────────────────────────────────────
    #
    # Identity FIRST, exactly as {VerbController} resolves it first and for the
    # same reason: an anonymous probe of any path under the mount answers `401
    # unauthenticated`, so this refusal never becomes a way to ask questions
    # without a token. It discloses nothing either way — `GET <endpoint>/schema`
    # is public and publishes every registered name — but the two answers should
    # not differ in their order of gates, or the pair of them becomes readable
    # as a difference.
    class VerbRefusalController < VerbController
      # GET <endpoint>/<name> where <name> is not a query drawn by this origin.
      def show
        refuse(:query)
      end

      # POST <endpoint>/<name> where <name> is not an action drawn by this origin.
      def create
        refuse(:run)
      end

      private

      # Runs {VerbController#descriptor_for!} for its REFUSALS only. That method
      # raises `MethodNotAllowed` for a name registered as the other kind and
      # `VerbNotFound` (carrying the registry's own name hint) for a name
      # registered as neither — the two answers this controller exists to give,
      # written once, in the class that also serves them on the happy path.
      #
      # Reaching the line after it means the name IS registered as this kind and
      # the operator did not draw its route.
      def refuse(command)
        name = params[:kiosk_verb].to_s
        resolve_identity!
        descriptor_for!(command, name)

        method = command == :query ? "GET" : "POST"
        raise Errors::Base,
          "#{name.inspect} is a registered #{command == :query ? "query" : "action"} at this " \
          "origin, but no route reaches it. This engine draws the protocol plane; an " \
          "operator draws ONE EXPLICIT ROUTE PER VERB. Add `#{method.downcase} " \
          "\"#{Kiosk.configuration.mount_path}/#{name}\", to: " \
          "\"kiosk/server/verb##{command == :query ? "show" : "create"}\", defaults: " \
          "{ kiosk_verb: \"#{name}\" }` to config/routes/kiosk.rb."
      end
    end
  end
end
