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
    # registry — since T-081 the ONLY thing that goes in one. The {Executor}
    # calls it like any other handler and needs to know nothing about it.
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
    # so the opaque cursor and the total still reach the wire — as the `Link`
    # and `X-Total-Count` response headers since T-092, never as body fields.
    #
    # ── Two gates on the method name ─────────────────────────────────────
    # The agent-supplied WIRE name never reaches Ruby: it is looked up in the
    # registry, which was built from the class's own declarations, and only the
    # method name recorded THERE is dispatched. `action_methods` is re-checked
    # at dispatch as a second, Rails-native gate (K-495).
    #
    # ── Errors (T-054: the wire contract, consumed Rails-natively) ───────
    # A handler that renders a non-2xx answers the wire like this:
    #
    #   * the body names an explicit vocabulary `error.code` — the HANDLER-side
    #     spelling, since what TRAVELS is the flat top-level `code` (K-1095) —
    #     whose canonical
    #     status ({Errors::CODES}) matches the rendered status → that code
    #     travels verbatim, extra envelope fields (`challenges`, …) included.
    #     This is how a plain `render json:, status:` says `rls_denied`, or a
    #     SPECIFIC 402 — naming, not guessing.
    #   * otherwise the status' lone wire code decides
    #     ({Errors::STATUS_CODES}; 402 and 500 deliberately have none) —
    #     400 → bad_request, 403 → forbidden, …
    #   * a status with no lone code is `action_failed`: the seam refuses to
    #     guess between codes that share a status.
    #
    # A handler may still RAISE a wire-only {Errors} class (a gate-style
    # `Errors::KycRequired`, say) — the raise propagates out of the
    # sub-dispatch untouched and the Executor re-raises it as-is. Rails-native
    # raises (`ActiveRecord::RecordNotFound`, `params.require`, anything the
    # host registered in `config.action_dispatch.rescue_responses`) are
    # mapped by the one `rescue_from` seam the mixin installs — see
    # {HandlerMixin::InstanceMethods#kiosk_rescue_to_wire}.
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

      # ── What the SUB-RESPONSE's headers do (K-823) ───────────────────────
      #
      # Exactly one of them survives the seam, and it is named rather than
      # inferred: `Cache-Control`, on a 2xx. Spec §3.7.4 grants the operator
      # one permission about a wire response's headers — "the default for a
      # `200` is `private, no-store`; an operator MAY relax it to `private,
      # max-age=N` for a genuinely identity-independent payload" — and on the
      # 0.4 per-verb wire the only code an operator writes is a handler, so a
      # seam that dropped every sub-response header made that published
      # permission unreachable by anybody. It read
      # `status, _headers, body = …` and that underscore WAS the bug.
      #
      # WHY THE LIST IS ONE ENTRY AND NOT "EVERYTHING THE HANDLER SET".
      # The sub-request is BUILT here, not received: {#build_env} copies the
      # caller's `HTTP_*` headers in, so Rails' own
      # `ActionController::Rendering#_set_vary_header` stamps `Vary: Accept` on
      # the handler's render — a header the handler never wrote and that would
      # be false on the wire, where the answer is JSON whatever the caller
      # asked for. A blanket copy would import that, plus `Content-Type`,
      # `ETag` and `Content-Length` computed for a body the wire re-serialises.
      # So the rule is the spec's rule: the operator gets a say over exactly
      # what §3.7 gives them a say over.
      #
      # 2xx ONLY, and that is §3.7.4's own scope: a non-2xx render does not
      # return from here at all, it becomes an {Errors::Base} in {#decode},
      # and a refusal's cache policy belongs to the wire (a 402's `no-store`
      # is the one directive §3.7.2 says an operator cannot relax).
      #
      # §3.7.3's `MUST NOT send public or s-maxage` is NOT enforced here.
      # It is enforced at the render seam, in {Headers.add_cache_policy}, so
      # that the one place a wire `Cache-Control` is decided is also the one
      # place the prohibition is applied — whatever route the value arrived by.
      PROPAGATED_HEADERS = %w[Cache-Control].freeze

      def call(args = {})
        controller = resolve_controller
        gate!(controller)

        env = build_env(controller, args)
        status, headers, body = controller.action(@method_name).call(env)
        publish_headers(status, headers)
        payload = decode(status, read_body(body))

        env[PAGE_KEY] ? paginate(payload) : payload
      end

      # Handy in `p`/logs and in the specs that assert what got registered.
      def inspect
        "#<#{self.class.name} #{@kind} #{@wire_name.inspect} → " \
          "#{controller_name || @controller}##{@method_name}>"
      end

      private

      # Copies {PROPAGATED_HEADERS} out of the sub-response into the sink the
      # wire opened on {CurrentRequest}. No sink means nobody is serving a wire
      # request — a direct {Executor} call or an RLS journey test — and then
      # this is a no-op rather than an error.
      #
      # Rack 3 down-cases response header names and ActionDispatch hands back a
      # case-insensitive `Rack::Headers`, but a controller built on a plain
      # Hash (specs, Metal) does not, so both spellings are asked for.
      def publish_headers(status, headers)
        sink = CurrentRequest.handler_headers
        return if sink.nil? || headers.nil?
        return unless status >= 200 && status < 300

        PROPAGATED_HEADERS.each do |name|
          value = headers[name] || headers[name.downcase]
          sink[name] = value.to_s unless value.nil? || value.to_s.empty?
        end
      end

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
      # error the answer NAMES (an explicit vocabulary `error.code` matching
      # the rendered status), or failing that the status' lone wire code
      # ({Errors::STATUS_CODES}) — see the Errors section of the class doc.
      def decode(status, raw)
        return parse_json(raw) if status >= 200 && status < 300

        parsed = begin
          parse_json(raw)
        rescue Errors::Base
          nil
        end
        raise wire_error(status, parsed)
      end

      # The {Errors::Base} a rendered non-2xx becomes. An explicit body code
      # must be IN the closed vocabulary AND agree with the rendered status —
      # anything else (an operator's own `code` field, a mislabelled status)
      # falls back to the status mapping, so the wire never carries an
      # invented code. A status with no lone code (402, 500, or anything
      # unmapped) is `action_failed`: refusing to guess is the contract.
      def wire_error(status, parsed)
        error_obj = parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"] : nil
        rendered  = error_obj && error_obj["code"].to_s
        code      = if rendered && Errors::CODES[rendered] == status
                      rendered
                    else
                      Errors::STATUS_CODES[status]
                    end
        if code.nil?
          return Errors::ActionFailed.new(error_message(parsed, status), hint: error_hint(parsed))
        end

        extra = error_obj && error_obj.except("code", "message", "hint").transform_keys(&:to_sym)
        Errors::WireError.new(error_message(parsed, status),
                              code: code, hint: error_hint(parsed), extra: extra)
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

      # `render_kiosk_page` rendered `{rows:, next_cursor:, total:}`; rebuild
      # the {Page} the Executor understands, so the opaque cursor and the total
      # reach the wire's `Link` and `X-Total-Count` headers (spec §8.4).
      def paginate(payload)
        unless payload.is_a?(Hash) && payload.key?("rows")
          raise Errors::ActionFailed.new(
            "query #{@wire_name.inspect} marked its response paginated but rendered no rows",
            hint: "use render_kiosk_page(rows, next_cursor:) — do not set the marker by hand",
          )
        end

        Page.new(rows:        payload["rows"],
                 next_cursor: payload["next_cursor"],
                 total:       payload["total"])
      end
    end
  end
end
