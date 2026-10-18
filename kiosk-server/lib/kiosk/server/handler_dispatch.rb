# frozen_string_literal: true

require 'json'
require 'stringio'
require 'action_controller'

module Kiosk
  module Server
    # The registry callable for a {HandlerMixin} verb: dispatches one controller action through
    # `Controller.action(name).call(env)` and turns its render into a return value or a wire error.
    class HandlerDispatch
      # Rack env keys set on the sub-request only; DISPATCH_KEY marks a dispatch through the wire.
      IDENTITY_KEY = 'kiosk.identity'
      DISPATCH_KEY = 'kiosk.dispatch'
      PAGE_KEY     = 'kiosk.page'

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
        answer  = Answer.new(@kind, @wire_name)
        payload = answer.decode(status, read_body(body))

        env[PAGE_KEY] ? answer.paginate(payload, **env[PAGE_KEY]) : payload
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
        return if sink.nil? || headers.nil? || !(200...300).cover?(status)

        PROPAGATED_HEADERS.each do |name|
          value = (headers[name] || headers[name.downcase]).to_s
          sink[name] = value unless value.empty?
        end
      end

      def resolve_controller
        return @controller unless @controller.is_a?(String)

        @controller.constantize
      rescue NameError
        # `verb_not_found`: nothing was addressed, and the caller should stop calling this name.
        raise Errors::VerbNotFound.new(
          "#{@kind} #{@wire_name.inspect} is registered to #{@controller}, which is not loaded",
          hint: 'the handler class was renamed or removed; restart the server after moving it'
        )
      end

      # The second check after the registry lookup: Rails' own `action_methods`.
      def gate!(controller)
        return if controller.respond_to?(:action_methods) &&
                  controller.action_methods.include?(@method_name)

        raise Errors::VerbNotFound.new(
          "#{@kind} #{@wire_name.inspect} is no longer dispatchable",
          hint: "#{controller_name || controller}##{@method_name} is not a public controller action"
        )
      end

      def build_env(controller, args)
        env = SubRequest.env(
          path_info: "/#{@kind}/#{@wire_name}", args: args,
          path_parameters: {
            controller: controller.respond_to?(:controller_path) ? controller.controller_path : nil,
            action: @method_name
          }
        )
        env[IDENTITY_KEY] = CurrentRequest.identity
        env[DISPATCH_KEY] = @wire_name
        env
      end

      def read_body(body)
        raw = +''
        body.each { |chunk| raw << chunk }
        raw
      ensure
        body.close if body.respond_to?(:close)
      end

      # The Rack env of one dispatch.
      module SubRequest
        module_function

        # A fresh Rack env per dispatch; the parsed args are injected as request parameters, not re-serialised.
        def env(path_info:, path_parameters:, args:)
          env = base(path_info)
          seed!(env, CurrentRequest.env)
          # `dup` so the handler cannot mutate the Executor's args.
          env['action_dispatch.request.request_parameters'] = args.is_a?(Hash) ? args.dup : {}
          env['action_dispatch.request.query_parameters']   = {}
          env['action_dispatch.request.path_parameters']    = path_parameters
          # The wire answers JSON whatever the caller's `Accept`, so a handler's template is its `.json` one.
          env['action_dispatch.request.formats'] = [Mime[:json]]
          env
        end

        def seed!(env, outer)
          return if outer.nil?

          SEEDED_KEYS.each { |key| env[key] = outer[key] if outer.key?(key) }
          outer.each { |key, value| env[key] = value if key.is_a?(String) && key.start_with?('HTTP_') }
        end

        BASE = {
          'REQUEST_METHOD' => 'POST',
          'SCRIPT_NAME' => '',
          'QUERY_STRING' => '',
          'SERVER_NAME' => 'localhost',
          'SERVER_PORT' => '80',
          'SERVER_PROTOCOL' => 'HTTP/1.1',
          'CONTENT_TYPE' => 'application/json',
          'CONTENT_LENGTH' => '0',
          'rack.url_scheme' => 'http'
        }.freeze

        def base(path_info)
          BASE.merge('PATH_INFO' => path_info, 'rack.input' => StringIO.new(+''), 'rack.errors' => $stderr)
        end
      end

      # A handler's render as the verb's answer: its payload, or the wire error it means.
      class Answer
        def initialize(kind, wire_name)
          @kind      = kind
          @wire_name = wire_name
        end

        # 2xx → the rendered JSON; otherwise the wire error it means.
        def decode(status, raw)
          return parse_json(raw) if status >= 200 && status < 300

          parsed = begin
            parse_json(raw)
          rescue Errors::Base
            nil
          end
          raise wire_error(status, parsed)
        end

        # The {Page} of `render_kiosk_page`: the rendered rows plus the page facts it recorded.
        def paginate(payload, next_cursor:, total:)
          unless payload.is_a?(Array)
            raise Errors::ActionFailed.new(
              "query #{@wire_name.inspect} answered a page that is not an array of rows",
              hint: "render_kiosk_page renders the rows it is given, or the action's template; " \
                    'either must be a JSON array'
            )
          end

          Page.new(rows: payload, next_cursor: next_cursor, total: total)
        end

        private

        # A body code travels only when it is in the vocabulary and matches the status; otherwise
        # the status's lone code decides, and with none it is `action_failed`.
        def wire_error(status, parsed)
          error_obj = parsed.is_a?(Hash) && parsed['error'].is_a?(Hash) ? parsed['error'] : nil
          code = code_for(error_obj, status)
          return Errors::ActionFailed.new(error_message(parsed, status), hint: error_hint(parsed)) if code.nil?

          extra = error_obj&.except('code', 'message', 'hint')&.transform_keys(&:to_sym)
          Errors::WireError.new(error_message(parsed, status),
                                code: code, hint: error_hint(parsed), extra: extra)
        end

        def code_for(error_obj, status)
          rendered = error_obj && error_obj['code'].to_s
          rendered && Errors::CODES[rendered] == status ? rendered : Errors::STATUS_CODES[status]
        end

        def parse_json(raw)
          return nil if raw.nil? || raw.strip.empty?

          JSON.parse(raw)
        rescue JSON::ParserError
          raise Errors::ActionFailed.new(
            "#{@kind} #{@wire_name.inspect} rendered a non-JSON body",
            hint: 'a Kiosk handler answers with `render json:` — HTML, redirects and ' \
                  '`send_file` have no place on the wire'
          )
        end

        # The operator's own message reaches the agent when the body carries one.
        def error_message(parsed, status)
          from_body = parsed.is_a?(Hash) ? (parsed['error'] || parsed['message']) : nil
          from_body = from_body['message'] if from_body.is_a?(Hash)
          return from_body.to_s unless from_body.nil? || from_body.to_s.empty?

          "#{@kind} #{@wire_name.inspect} answered #{status}"
        end

        def error_hint(parsed)
          return nil unless parsed.is_a?(Hash)

          hint = parsed['hint'] || (parsed['error'].is_a?(Hash) ? parsed['error']['hint'] : nil)
          hint&.to_s
        end
      end
    end
  end
end
