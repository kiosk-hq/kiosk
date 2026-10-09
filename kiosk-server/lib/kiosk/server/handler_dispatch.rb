# frozen_string_literal: true

require "json"
require "stringio"
require "action_controller"
require "kiosk/server/current_request"
require "kiosk/server/errors"
require "kiosk/server/result"

module Kiosk
  module Server
    # The registry callable for a {HandlerMixin} verb: dispatches one controller action through
    # `Controller.action(name).call(env)` and turns its render into a return value or a wire error.
    class HandlerDispatch
      # Rack env keys set on the sub-request only; DISPATCH_KEY marks a dispatch through the wire.
      IDENTITY_KEY = "kiosk.identity"
      DISPATCH_KEY = "kiosk.dispatch"
      PAGE_KEY     = "kiosk.page"
      # The exception `kiosk_rescue_to_wire` handled, raised here as the wire error's `cause`.
      RESCUED_KEY  = "kiosk.rescued"

      # Copied from the wire request; `parameter_filter` keeps the handler's params log line filtered.
      SEEDED_KEYS = %w[
        REMOTE_ADDR SERVER_NAME SERVER_PORT SERVER_PROTOCOL
        rack.url_scheme rack.session rack.errors
        action_dispatch.request_id action_dispatch.remote_ip
        action_dispatch.parameter_filter
      ].freeze

      attr_reader :method_name, :wire_name, :kind

      # A named controller is stored by name and re-resolved per call, so code reloading picks up edits.
      def initialize(controller:, method_name:, wire_name:, kind:)
        @controller  = controller.is_a?(Class) && controller.name ? controller.name : controller
        @method_name = method_name.to_s
        @wire_name   = wire_name.to_s
        @kind        = kind
      end

      # nil for an anonymous controller class.
      def controller_name = @controller.is_a?(String) ? @controller : @controller.name

      # The one sub-response header a handler controls: `Cache-Control`, on a 2xx (§3.7.4).
      PROPAGATED_HEADERS = %w[Cache-Control].freeze

      def call(args = {})
        controller = resolve_controller
        gate!(controller)

        env = build_env(controller, args)
        status, headers, body = controller.action(@method_name).call(env)
        publish_headers(status, headers)
        payload = decode(status, read_body(body), rescued: env[RESCUED_KEY])

        env[PAGE_KEY] ? paginate(payload) : payload
      end

      # Handy in `p`/logs and in the specs that assert what got registered.
      def inspect
        "#<#{self.class.name} #{@kind} #{@wire_name.inspect} → " \
          "#{controller_name || @controller}##{@method_name}>"
      end

      private

      # No sink means no wire request is being served. Rack 3 down-cases header names; a plain Hash does not.
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
        # `verb_not_found`: nothing was addressed, and the caller should stop calling this name.
        raise Errors::VerbNotFound.new(
          "#{@kind} #{@wire_name.inspect} is registered to #{@controller}, which is not loaded",
          hint: "the handler class was renamed or removed; restart the server after moving it",
        )
      end

      # The second check after the registry lookup: Rails' own `action_methods`.
      def gate!(controller)
        return if controller.respond_to?(:action_methods) &&
                  controller.action_methods.include?(@method_name)

        raise Errors::VerbNotFound.new(
          "#{@kind} #{@wire_name.inspect} is no longer dispatchable",
          hint: "#{controller_name || controller}##{@method_name} is not a public controller action",
        )
      end

      # A fresh Rack env per dispatch; the parsed args are injected as request parameters, not re-serialised.
      def build_env(controller, args)
        outer = CurrentRequest.env
        env   = base_env
        if outer
          SEEDED_KEYS.each { |key| env[key] = outer[key] if outer.key?(key) }
          outer.each { |key, value| env[key] = value if key.is_a?(String) && key.start_with?("HTTP_") }
        end

        # `dup` so the handler cannot mutate the Executor's args.
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

      # 2xx → the rendered JSON; otherwise the wire error, with `rescued` as its `cause`.
      def decode(status, raw, rescued: nil)
        return parse_json(raw) if status >= 200 && status < 300

        parsed = begin
          parse_json(raw)
        rescue Errors::Base
          nil
        end
        error = wire_error(status, parsed)
        rescued.is_a?(::Exception) ? raise(error, cause: rescued) : raise(error)
      end

      # A body code travels only when it is in the vocabulary and matches the status; otherwise
      # the status's lone code decides, and with none it is `action_failed`.
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
      rescue JSON::ParserError
        raise Errors::ActionFailed.new(
          "#{@kind} #{@wire_name.inspect} rendered a non-JSON body",
          hint: "a Kiosk handler answers with `render json:` — HTML, redirects and " \
                "`send_file` have no place on the wire",
        )
      end

      # The operator's own message reaches the agent when the body carries one.
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

      # Rebuilds the {Page} from `render_kiosk_page`'s `{rows:, next_cursor:, total:}`.
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
