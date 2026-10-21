# frozen_string_literal: true

require 'json'

module Kiosk
  module Server
    # How a controller that includes {Kiosk::Handler} answers a verb call.
    # {Routing::VerbRoute} sends the protocol request to the action that declares
    # the verb. Around that action this module runs the gates of {VerbWire},
    # the session and the transaction, and writes the action's render as the
    # protocol answer.
    module HandlerServing
      include VerbWire

      # The Rack env key where {Routing::VerbRoute} puts the published name it routed.
      VERB_KEY = 'kiosk.verb'

      # The one header of an action's render that reaches the response: `Cache-Control`, on a 2xx (§3.7.4).
      PROPAGATED_HEADERS = %w[Cache-Control].freeze

      private

      # Outside the operator's callbacks and `rescue_from`, which all run inside `super`.
      def process_action(*)
        declaration = self.class.kiosk_declarations[request.get_header(VERB_KEY)]
        return kiosk_refuse_unrouted unless declaration && declaration[:method_name] == action_name

        # Parses the parameters first, so a malformed body is refused before the identity.
        request.parameters
        kiosk_render_answer(kiosk_call(declaration) { super })
      rescue Errors::Base => e
        kiosk_render_refusal(e)
      rescue ::ActionDispatch::Http::Parameters::ParseError
        kiosk_render_refusal(Errors.malformed_json(hint: BODY_HINT))
      end

      # The verb's {Result}: the protocol's gates, then the action inside the session.
      def kiosk_call(declaration, &)
        kind     = declaration[:kind]
        name     = @_kiosk_wire_name = declaration[:wire_name]
        command  = kind == :query ? :query : :run
        identity = resolve_identity!
        args     = arguments_for(command, name, HandlerMixin.registry_for(kind).describe(name))
        handler  = ->(handler_args) { kiosk_answer(kind, handler_args, &) }
        call_wire(command: command, args: args, identity: identity, name: name, handler: handler)
      end

      # Runs the action with the decoded arguments as its parameters, and reads its render as the answer.
      def kiosk_answer(kind, args)
        kiosk_wire_parameters!(args)
        yield

        status, headers, body = response.to_a
        @_kiosk_headers = kiosk_propagated_headers(status, headers)
        Answer.new(kind, @_kiosk_wire_name).value(status, kiosk_read_body(body), @_kiosk_page)
      end

      # The action's `params` are the decoded arguments; the protocol answers JSON whatever the caller's
      # `Accept`, so an action's template is its `.json` one.
      def kiosk_wire_parameters!(args)
        request.set_header('action_dispatch.request.request_parameters', args.dup)
        request.set_header('action_dispatch.request.query_parameters', {})
        request.delete_header('action_dispatch.request.parameters')
        request.set_header('action_dispatch.request.formats', [Mime[:json]])
      end

      def kiosk_render_answer(result)
        kiosk_fresh_response!
        @_kiosk_headers.each { |header, value| response.headers[header] = value }
        render_result(result)
      end

      def kiosk_propagated_headers(status, headers)
        return {} unless (200...300).cover?(status)

        PROPAGATED_HEADERS.index_with { headers[it].to_s }.reject { |_, value| value.empty? }
      end

      def kiosk_read_body(body)
        raw = +''
        body.each { |chunk| raw << chunk }
        raw
      ensure
        body.close if body.respond_to?(:close)
      end

      def kiosk_render_refusal(error)
        kiosk_fresh_response!
        render_wire_error(error)
      end

      # The action's render was read; the protocol answer is written into a fresh response.
      def kiosk_fresh_response!
        set_response!(self.class.make_response!(request))
        @_response_body = nil
      end

      # A route drawn straight at a handler action, not through `kiosk do`, answers 404 `verb_not_found`.
      def kiosk_refuse_unrouted
        problem = Errors::VerbNotFound.new(
          'Kiosk handlers are reachable through the Kiosk HTTP API only',
          hint: "call the verb's own route — " \
                "GET #{Kiosk.configuration.mount_path}/<query-name> or " \
                "POST #{Kiosk.configuration.mount_path}/<action-name>"
        ).to_problem

        render json: problem, status: :not_found, content_type: Errors::PROBLEM_CONTENT_TYPE
      end

      # An action's render as the verb's answer: its payload, or the Kiosk error it means.
      class Answer
        def initialize(kind, wire_name)
          @kind      = kind
          @wire_name = wire_name
        end

        # A query answers its rows, or a {Page} when `render_kiosk_page` recorded the page facts.
        def value(status, raw, page)
          payload = decode(status, raw)
          return payload unless @kind == :query

          rows!(payload)
          page ? Page.new(rows: payload, **page) : payload
        end

        private

        # 2xx → the rendered JSON; otherwise the Kiosk error it means.
        def decode(status, raw)
          return parse_json(raw) if status >= 200 && status < 300

          parsed = begin
            parse_json(raw)
          rescue Errors::Base
            nil
          end
          raise wire_error(status, parsed)
        end

        # A query answers an array of rows, paginated or not (§8.2).
        def rows!(payload)
          return if payload.is_a?(Array)

          raise Errors::ActionFailed.new(
            "query #{@wire_name.inspect} answered something that is not an array of rows",
            hint: 'A query renders a JSON array of rows, paginated or not.'
          )
        end

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
                  '`send_file` have no place in a Kiosk response'
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
