# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "kiosk/pow/equihash/solver"

module Kiosk
  module TestHelpers
    # Any method at any path of an origin, with the whole answer returned. With
    # `pay_tolls: true` it solves a proof-of-work toll and sends the request once more.
    #
    #   wire = Kiosk::TestHelpers::Wire.new(base_url: "http://127.0.0.1:3006")
    #   status, problem = wire.post_json("/kiosk/edit_listing", { listing_id: "junk" }, Wire.bearer(token))
    class Wire
      # One answer: a body that is not JSON reads as `{}`, an unreachable origin as status 0.
      Response = Data.define(:status, :headers, :body, :raw_body, :proofs) do
        def initialize(status:, body:, headers: {}, raw_body: "", proofs: 0) = super

        def [](header) = headers[header.to_s.downcase]

        # Whether the client paid a proof-of-work toll and sent the request again.
        def pow_retried = proofs.positive?
      end

      METHODS = {
        get:     Net::HTTP::Get,
        post:    Net::HTTP::Post,
        put:     Net::HTTP::Put,
        patch:   Net::HTTP::Patch,
        delete:  Net::HTTP::Delete,
        head:    Net::HTTP::Head,
        options: Net::HTTP::Options,
      }.freeze

      # The scheme decides TLS.
      def self.http_for(uri, open_timeout: nil, read_timeout: nil)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == "https"
        http.open_timeout = open_timeout if open_timeout
        http.read_timeout = read_timeout if read_timeout
        http
      end

      def self.bearer(token) = { "Authorization" => "Bearer #{token}" }

      attr_reader :base_url

      def initialize(base_url:, pay_tolls: false, open_timeout: 10, read_timeout: 30)
        @base_url     = base_url.to_s.chomp("/")
        @pay_tolls    = pay_tolls
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def bearer(token) = self.class.bearer(token)

      def post_json(path, body = {}, headers = {}) = post(path, body, headers).then { [_1.status, _1.body] }

      def get_json(path, params = {}, headers = {}) = get(path, params, headers).then { [_1.status, _1.body] }

      def post(path, body = {}, headers = {}) = request(:post, path, body:, headers:)

      def get(path, params = {}, headers = {}) = request(:get, path, params:, headers:)

      def post_form(path, form, headers = {})
        request(:post, path, headers:) { _1.set_form_data(form) }
      end

      def request(method, path, body: nil, params: nil, headers: {}, &form)
        klass = METHODS.fetch(method.to_s.downcase.to_sym) { raise ArgumentError, "unsupported HTTP method #{method.inspect}" }
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) if params&.any?
        answer = deliver(klass, uri, body, headers, &form)
        challenges = answer.body["challenges"] if @pay_tolls && answer.status == 402 && answer.body.is_a?(Hash)
        return answer unless challenges.is_a?(Array) && challenges.any?

        proofs = challenges.map { { challenge: _1, nonce: Kiosk::Pow::Equihash.solve(_1) } }
        deliver(klass, uri, body, headers.merge("Kiosk-PoW" => JSON.generate(proofs)), &form).with(proofs: proofs.size)
      end

      private

      def deliver(klass, uri, body, headers)
        request = klass.new(uri, body.nil? ? headers : { "Content-Type" => "application/json" }.merge(headers))
        request.body = JSON.generate(body) unless body.nil?
        yield request if block_given?
        begin
          answer = self.class.http_for(uri, open_timeout: @open_timeout, read_timeout: @read_timeout).request(request)
        rescue StandardError => e
          return Response.new(status: 0, body: { "error" => e.class.name, "detail" => e.message })
        end
        response(answer)
      end

      def response(answer)
        raw_body = answer.body.to_s
        body = begin
          JSON.parse(raw_body)
        rescue JSON::ParserError
          {}
        end
        headers = answer.each_header.to_h { |name, value| [name.downcase, value] }
        Response.new(status: answer.code.to_i, headers:, body:, raw_body:)
      end
    end
  end
end
