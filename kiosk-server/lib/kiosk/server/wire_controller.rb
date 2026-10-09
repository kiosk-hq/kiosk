# frozen_string_literal: true

require "action_controller"
require "action_dispatch/http/parameters"
require "cgi"
require "json"
require "kiosk/server/caller_timezone"
require "kiosk/server/current_request"
require "kiosk/server/executor"
require "kiosk/server/errors"
require "kiosk/server/headers"
require "kiosk/server/pow_gate"
require "kiosk/server/request_validation"
require "kiosk/server/schema_document"

module Kiosk
  module Server
    # The reserved `GET <endpoint>/schema` (public) and `POST <endpoint>/pay`,
    # and the base every wire controller inherits its seams from.
    # Wire response (JSON): success is the handler's payload VERBATIM; an error
    # is an RFC 9457 problem document.
    class WireController < ::ActionController::API
      rescue_from Errors::Base, with: :render_wire_error

      # Touching `params` parses the body before any Kiosk code runs.
      rescue_from ::ActionDispatch::Http::Parameters::ParseError do
        render_wire_error(
          Errors.malformed_json(
            hint: "an action's arguments are a JSON object in the request body; " \
                  "a query's are in the query string.",
          ),
        )
      end

      # No identity, no toll. A stale `?v=` still gets the current catalog,
      # with the short TTL.
      def schema
        render_public_document(
          SchemaDocument.json, version: SchemaDocument.digest, etag: SchemaDocument.etag
        )
      end

      def pay
        body     = parse_body!
        identity = resolve_identity!

        # After identity: 401 before 400.
        RequestValidation.validate_body!(body, exchange: "POST <endpoint>/pay")

        execute_wire(command: :pay, args: body, identity: identity, name: "pay")
      end

      private

      # Shared with {OpenApiController#show}.
      def render_public_document(json, version:, etag:, content_type: nil)
        Kiosk::Server::Headers.add_to(response.headers)
        Kiosk::Server::Headers.add_public_cache_policy(
          response.headers, etag: etag, immutable: params[:v].to_s == version
        )

        if if_none_match?(etag)
          head :not_modified
        else
          options = { json: json, status: :ok }
          options[:content_type] = content_type if content_type
          render(**options)
        end

        # Last: Rails stamps `Vary: Accept` at render time.
        response.headers.delete("Vary")
      end

      # RFC 9110 §13.1.2; not `fresh_when`, which hashes the validator it is given.
      def if_none_match?(etag)
        raw = request.get_header("HTTP_IF_NONE_MATCH").to_s
        return false if raw.empty?
        return true  if raw.strip == "*"

        raw.split(",").any? { |tag| tag.strip.delete_prefix("W/") == etag }
      end

      # `command` is the policy verb ({Executor::VERBS}); `name` the wire name.
      def execute_wire(command:, args:, identity:, name:)
        # Refused with the arguments, before the toll.
        timezone = CallerTimezone.from_env(request.env)
        toll!(identity: identity, command: command, name: name, body: args)

        # A handler's own `Cache-Control` comes back here, ahead of the cache policy (§3.7.4).
        handler_headers = {}
        result = CurrentRequest.with(identity: identity, env: request.env,
                                     handler_headers: handler_headers,
                                     timezone: timezone) do
          Executor.call(
            kind:       command,
            args:       args,
            identity:   identity,
            connection: connection_for(identity),
            name:       name,
          )
        end
        handler_headers.each { |header, value| response.headers[header] = value }

        render_result(result)
      end

      def toll!(identity:, command:, name:, body:)
        pow = PowGate.proofs_from_header(request.get_header("HTTP_KIOSK_POW"))

        # A malformed proof is a 400, not a silent fresh 402.
        if Kiosk.configuration.validate_requests && !PowGate.blank?(pow)
          RequestValidation.validate_proofs!(pow)
        end

        PowGate.gate(
          identity: identity, command: command, method: request.request_method,
          verb: name, body: body, pow: pow
        )
      end

      def render_result(result)
        add_pagination_headers(result)
        render_wire_body(result.to_payload, status: result.http_status)
      end

      # §8.4: `Link` only on a truncated page; `X-Total-Count` is the array's
      # length on a complete answer, else only what the handler passed.
      def add_pagination_headers(result)
        return unless result.kind == :rows

        if (cursor = result.next_cursor)
          add_link_header(next_page_link(cursor))
        end

        total = result.total
        total = result.payload.length if total.nil? && result.next_cursor.nil? &&
                                         result.payload.is_a?(::Array)
        response.headers["X-Total-Count"] = total.to_s unless total.nil?
      end

      def add_link_header(value)
        existing = response.headers["Link"].to_s
        response.headers["Link"] = existing.empty? ? value : "#{existing}, #{value}"
      end

      # Edits the raw query string, so the caller's bracket spellings survive.
      def next_page_link(cursor)
        pairs = request.query_string.to_s.split("&").reject do |pair|
          pair.split("=", 2).first == "cursor"
        end
        pairs << "cursor=#{CGI.escape(cursor.to_s)}"

        %(<#{request.base_url}#{request.path}?#{pairs.join("&")}>; rel="next")
      end

      def render_wire_error(error)
        render_wire_body(
          error.to_problem,
          status:       error.http_status,
          error:        error,
          content_type: Errors::PROBLEM_CONTENT_TYPE,
        )
      end

      def resolve_identity!
        identity = IdentityResolution.resolve(request)
        raise Errors::Unauthenticated, "no identity resolved from request" if identity.nil?

        identity
      end

      def parse_body!
        raw = request.raw_post
        return {} if raw.nil? || raw.empty?

        parsed = JSON.parse(raw, symbolize_names: true)
        unless parsed.is_a?(Hash)
          raise Errors::BadRequest, "request body must be a JSON object"
        end

        parsed
      rescue JSON::ParserError
        raise Errors.malformed_json(
          hint: "an action's arguments are a JSON object in the request body; " \
                "a query's are in the query string.",
        )
      end

      # A lease: the GUCs and `pay`'s three transactions need one connection per request.
      def connection_for(_identity)
        ::ActiveRecord::Base.lease_connection
      end

      def render_wire_body(body, status:, error: nil, content_type: nil)
        Kiosk::Server::Headers.add_to(response.headers)
        Kiosk::Server::Headers.add_cache_policy(
          response.headers, status: ::Rack::Utils.status_code(status)
        )
        if error
          error.response_headers.each { |name, value| response.set_header(name, value) }
          if (challenge = www_authenticate_for(error))
            response.set_header("WWW-Authenticate", challenge)
          end
        end
        options = { json: body, status: status }
        options[:content_type] = content_type if content_type
        render(**options)
      end

      # RFC 7235: the header names which 402 gate answered, keyed on the code.
      def www_authenticate_for(error)
        issuer = Kiosk.current_issuer
        case error.code
        when "pow_required"
          %(Kiosk-PoW realm="#{issuer}")
        when "payment_setup_required"
          %(Payment realm="#{issuer}", method="ap2")
        end
      end
    end
  end
end
