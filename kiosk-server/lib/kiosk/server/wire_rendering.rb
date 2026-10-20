# frozen_string_literal: true

require 'cgi'

module Kiosk
  module Server
    # How a wire answer is written: headers, cache policy, body. Success is the
    # verb's payload; a refusal is an RFC 9457 problem document.
    module WireRendering
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
          render(**render_options(json, :ok, content_type))
        end

        # Last: Rails stamps `Vary: Accept` at render time.
        response.headers.delete('Vary')
      end

      # RFC 9110 §13.1.2; not `fresh_when`, which hashes the validator it is given.
      def if_none_match?(etag)
        raw = request.get_header('HTTP_IF_NONE_MATCH').to_s
        return false if raw.empty?
        return true  if raw.strip == '*'

        raw.split(',').any? { |tag| tag.strip.delete_prefix('W/') == etag }
      end

      def render_result(result)
        add_pagination_headers(result)
        render_wire_body(result.to_payload, status: result.http_status)
      end

      # §8.4: `Link` only on a truncated page; `X-Total-Count` is the array's
      # length on a complete answer, else only what the handler passed.
      def add_pagination_headers(result)
        return unless result.kind == :rows

        add_link_header(next_page_link(result.next_cursor)) if result.next_cursor
        total = page_total(result)
        response.headers['X-Total-Count'] = total.to_s unless total.nil?
      end

      def page_total(result)
        return result.total unless result.total.nil?

        result.payload.length if result.next_cursor.nil? && result.payload.is_a?(::Array)
      end

      def add_link_header(value)
        existing = response.headers['Link'].to_s
        response.headers['Link'] = existing.empty? ? value : "#{existing}, #{value}"
      end

      # Edits the raw query string, so the caller's bracket spellings survive.
      def next_page_link(cursor)
        pairs = request.query_string.to_s.split('&').reject do |pair|
          pair.split('=', 2).first == 'cursor'
        end
        pairs << "cursor=#{CGI.escape(cursor.to_s)}"

        %(<#{request.base_url}#{request.path}?#{pairs.join('&')}>; rel="next")
      end

      def render_wire_error(error)
        render_wire_body(
          error.to_problem,
          status: error.http_status,
          error: error,
          content_type: Errors::PROBLEM_CONTENT_TYPE
        )
      end

      def render_wire_body(body, status:, error: nil, content_type: nil)
        Kiosk::Server::Headers.add_to(response.headers)
        Kiosk::Server::Headers.add_cache_policy(
          response.headers, status: ::Rack::Utils.status_code(status)
        )
        add_error_headers(error) if error
        render(**render_options(body, status, content_type))
      end

      def render_options(body, status, content_type)
        options = { json: body, status: status }
        options[:content_type] = content_type if content_type
        options
      end

      def add_error_headers(error)
        error.response_headers.each { |name, value| response.set_header(name, value) }
        challenge = www_authenticate_for(error)
        response.set_header('WWW-Authenticate', challenge) if challenge
      end

      # RFC 7235: the header names which 402 gate answered, keyed on the code.
      def www_authenticate_for(error)
        issuer = Kiosk.current_issuer
        case error.code
        when 'pow_required'
          %(Kiosk-PoW realm="#{issuer}")
        when 'payment_setup_required'
          %(Payment realm="#{issuer}", method="ap2")
        end
      end
    end
  end
end
