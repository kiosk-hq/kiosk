# frozen_string_literal: true

require "json"
require "stringio"
require "action_controller"
require "kiosk/server/current_request"
require "kiosk/server/errors"
require "kiosk/server/result"

module Kiosk
  module Server
    # The callable a {HandlerMixin} declaration puts in the Actions/Queries
    # registry. Registered like any other handler, so it coexists with the
    # `register(name) { |args| … }` blocks the demos still use; the {Executor}
    # cannot tell the two apart and needs no change to run either.
    #
    # Calling it dispatches ONE controller action through the router's own
    # mechanism — `Controller.action(:name).call(env)` — so the handler is a
    # plain Rails action: `before_action` filters run, `rescue_from` applies,
    # `params` is `ActionController::Parameters`, and the answer is whatever it
    # `render`s.
    #
    # ── What reaches the wire ────────────────────────────────────────────
    # The rendered JSON body becomes the handler's return value, which the
    # Executor wraps in a {Result} exactly as it wraps a block handler's:
    # a query's array of rows lands under `rows`, an action's object under
    # `value`. A query that called `render_kiosk_page` comes back as a {Page}
    # so the `next` cursor still reaches the envelope.
    #
    # ── Two gates on the method name ─────────────────────────────────────
    # The agent-supplied WIRE name never reaches Ruby: it is looked up in the
    # registry, which was built from the class's own declarations, and only the
    # method name recorded THERE is dispatched. `action_methods` is re-checked
    # at dispatch as a second, Rails-native gate (K-495).
    #
    # ── Errors ───────────────────────────────────────────────────────────
    # A handler that renders a non-2xx gets that status mapped to the wire error
    # whose CODE matches (400 → bad_request, 403 → forbidden, …). The mapping is
    # deliberately thin: it covers the Rails-idiomatic `render json:, status:`
    # and nothing else. A handler needing a wire code no HTTP status can carry
    # (`pow_required`, `payment_setup_required`, `spending_cap_exceeded`, …)
    # raises the {Errors} class instead — the raise propagates out of the
    # sub-dispatch untouched and the Executor re-raises it as-is. Consolidating
    # this into ONE `rescue_from` seam is T-054, which owns the taxonomy.
    class HandlerDispatch
      # Rack env keys this seam sets on the SUB-request (never on the wire
      # request). `kiosk.dispatch` is the marker HandlerMixin's guard checks so
      # a handler controller that an operator also ROUTES cannot be reached
      # from outside the wire.
      IDENTITY_KEY = "kiosk.identity"
      DISPATCH_KEY = "kiosk.dispatch"
      PAGE_KEY     = "kiosk.page"

      # Keys copied from the wire request into the sub-request, so a handler
      # sees the caller's headers, address and request id. Everything else is
      # rebuilt: the outer env carries a CONSUMED `rack.input` and memoised
      # `action_dispatch.request.parameters`, which must not leak in.
      SEEDED_KEYS = %w[
        REMOTE_ADDR SERVER_NAME SERVER_PORT SERVER_PROTOCOL
        rack.url_scheme rack.session rack.errors
        action_dispatch.request_id action_dispatch.remote_ip
      ].freeze

      # Rails-idiomatic statuses a handler renders → the wire error carrying the
      # matching CODE. 402 is absent ON PURPOSE: three different wire codes use
      # it (pow_required / payment_setup_required / payment_failed) and guessing
      # between them would put the wrong code on the wire.
      STATUS_ERRORS = {
        400 => Errors::BadRequest,
        401 => Errors::Unauthenticated,
        403 => Errors::Forbidden,
        404 => Errors::NotFound,
        409 => Errors::Conflict,
        422 => Errors::BadRequest,
        429 => Errors::QuotaExceeded,
      }.freeze

      attr_reader :method_name, :wire_name, :kind

      # @param controller [Class, String] the handler class, or its NAME. A
      #   named class is stored as a String and re-resolved on every call, so
      #   Zeitwerk reloading in development picks up handler edits without a
      #   server restart (K-495 charge 2). Anonymous classes (specs) are held
      #   directly.
      # @param method_name [Symbol, String] the controller action to dispatch.
      # @param wire_name [String] the name agents call it by.
      # @param kind [Symbol] :action or :query — used in messages only.
      def initialize(controller:, method_name:, wire_name:, kind:)
        @controller  = controller.is_a?(Class) && controller.name ? controller.name : controller
        @method_name = method_name.to_s
        @wire_name   = wire_name.to_s
        @kind        = kind
      end

      # @return [String, nil] the controller's constant name, nil when it was
      #   registered as an anonymous class.
      def controller_name = @controller.is_a?(String) ? @controller : @controller.name

      def call(args = {})
        controller = resolve_controller
        gate!(controller)

        env = build_env(controller, args)
        status, _headers, body = controller.action(@method_name).call(env)
        payload = decode(status, read_body(body))

        env[PAGE_KEY] ? paginate(payload) : payload
      end

      # Handy in `p`/logs and in the specs that assert what got registered.
      def inspect
        "#<#{self.class.name} #{@kind} #{@wire_name.inspect} → " \
          "#{controller_name || @controller}##{@method_name}>"
      end

      private

      def resolve_controller
        return @controller unless @controller.is_a?(String)

        @controller.constantize
      rescue NameError
        raise Errors::NotFound.new(
          "#{@kind} #{@wire_name.inspect} is registered to #{@controller}, which is not loaded",
          hint: "the handler class was renamed or removed; restart the server after moving it",
        )
      end

      # Second gate (the first is that the wire name only ever resolves through
      # the registry). `action_methods` is Rails' own answer to "may this be
      # dispatched", so a handler method that stopped being public — or a class
      # that no longer defines it at all — is a clean 404, not a 500.
      def gate!(controller)
        return if controller.respond_to?(:action_methods) &&
                  controller.action_methods.include?(@method_name)

        raise Errors::NotFound.new(
          "#{@kind} #{@wire_name.inspect} is no longer dispatchable",
          hint: "#{controller_name || controller}##{@method_name} is not a public controller action",
        )
      end

      # A fresh, minimal Rack env for ONE handler dispatch, seeded from the wire
      # request when there is one (there is not, for a Kiosk RLS journey test or
      # a direct Executor call).
      #
      # Params are injected as `action_dispatch.request.request_parameters`,
      # which `ActionDispatch::Http::Parameters#POST` returns verbatim — so the
      # args the Executor already parsed are NOT re-serialised and re-parsed,
      # and `params` in the handler is the ordinary
      # `ActionController::Parameters` with indifferent access.
      def build_env(controller, args)
        outer = CurrentRequest.env
        env   = base_env
        if outer
          SEEDED_KEYS.each { |key| env[key] = outer[key] if outer.key?(key) }
          outer.each { |key, value| env[key] = value if key.is_a?(String) && key.start_with?("HTTP_") }
        end

        # `dup`: the sub-request must not be able to mutate the args hash the
        # Executor still holds.
        env["action_dispatch.request.request_parameters"] = args.is_a?(Hash) ? args.dup : {}
        env["action_dispatch.request.query_parameters"]   = {}
        env["action_dispatch.request.path_parameters"]    = {
          controller: controller.respond_to?(:controller_path) ? controller.controller_path : nil,
          action:     @method_name,
        }
        env[IDENTITY_KEY] = CurrentRequest.identity
        env[DISPATCH_KEY] = @wire_name
        env
      end

      def base_env
        {
          "REQUEST_METHOD"  => "POST",
          "SCRIPT_NAME"     => "",
          "PATH_INFO"       => "/#{@kind}/#{@wire_name}",
          "QUERY_STRING"    => "",
          "SERVER_NAME"     => "localhost",
          "SERVER_PORT"     => "80",
          "SERVER_PROTOCOL" => "HTTP/1.1",
          "CONTENT_TYPE"    => "application/json",
          "CONTENT_LENGTH"  => "0",
          "rack.url_scheme" => "http",
          "rack.input"      => StringIO.new(+""),
          "rack.errors"     => $stderr,
        }
      end

      def read_body(body)
        raw = +""
        body.each { |chunk| raw << chunk }
        raw
      ensure
        body.close if body.respond_to?(:close)
      end

      # 2xx → the parsed JSON the handler rendered. Anything else → the wire
      # error for that status (see {STATUS_ERRORS}).
      def decode(status, raw)
        return parse_json(raw) if status >= 200 && status < 300

        error_class = STATUS_ERRORS[status] || Errors::ActionFailed
        parsed      = begin
          parse_json(raw)
        rescue Errors::Base
          nil
        end
        raise error_class.new(error_message(parsed, status), hint: error_hint(parsed))
      end

      def parse_json(raw)
        return nil if raw.nil? || raw.strip.empty?

        JSON.parse(raw)
      rescue JSON::ParserError => e
        raise Errors::ActionFailed.new(
          "#{@kind} #{@wire_name.inspect} rendered a non-JSON body: #{e.message}",
          hint: "a Kiosk handler answers with `render json:` — HTML, redirects and " \
                "`send_file` have no place on the wire",
        )
      end

      # Reuses whatever the handler said, so an operator's own message reaches
      # the agent instead of being replaced by a generic one.
      def error_message(parsed, status)
        from_body = parsed.is_a?(Hash) ? (parsed["error"] || parsed["message"]) : nil
        from_body = from_body["message"] if from_body.is_a?(Hash)
        return from_body.to_s unless from_body.nil? || from_body.to_s.empty?

        "#{@kind} #{@wire_name.inspect} answered #{status}"
      end

      def error_hint(parsed)
        return nil unless parsed.is_a?(Hash)

        hint = parsed["hint"] || (parsed["error"].is_a?(Hash) ? parsed["error"]["hint"] : nil)
        hint&.to_s
      end

      # `render_kiosk_page` rendered `{rows:, next_cursor:}`; rebuild the {Page}
      # the Executor understands so the opaque cursor reaches the envelope's
      # `next` field.
      def paginate(payload)
        unless payload.is_a?(Hash) && payload.key?("rows")
          raise Errors::ActionFailed.new(
            "query #{@wire_name.inspect} marked its response paginated but rendered no rows",
            hint: "use render_kiosk_page(rows, next_cursor:) — do not set the marker by hand",
          )
        end

        Page.new(rows: payload["rows"], next_cursor: payload["next_cursor"])
      end
    end
  end
end
