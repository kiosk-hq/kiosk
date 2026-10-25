# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'kiosk/test_helpers/dpop'
require 'kiosk/test_helpers/pow_solver'

module Kiosk
  module TestHelpers
    # Any method at any path of an origin, with the whole answer returned. With
    # `pay_tolls: true` it solves a proof-of-work toll and sends the request once more.
    #
    #   wire = Kiosk::TestHelpers::Wire.new(base_url: "http://127.0.0.1:3006")
    #   status, problem = wire.post_json("/kiosk/edit_listing", { listing_id: "junk" }, wire.dpop(token, key))
    class Wire
      # One answer: a body that is not JSON reads as `{}`, an unreachable origin as status 0.
      Response = Data.define(:status, :headers, :body, :raw_body, :proofs) do
        def initialize(status:, body:, headers: {}, raw_body: '', proofs: 0) = super

        def [](header) = headers[header.to_s.downcase]

        # Whether the client solved a proof-of-work toll and sent the request again.
        def pow_retried? = proofs.positive?
      end

      METHODS = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        put: Net::HTTP::Put,
        patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete,
        head: Net::HTTP::Head,
        options: Net::HTTP::Options
      }.freeze

      # The scheme decides TLS.
      def self.http_for(uri, open_timeout: nil, read_timeout: nil)
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl      = uri.scheme == 'https'
        http.open_timeout = open_timeout if open_timeout
        http.read_timeout = read_timeout if read_timeout
        http
      end

      # An access token and the key it is bound to. As a header value, the protocol
      # sends it as `Authorization: DPoP <token>` with a proof for that request;
      # with no token, as the proof alone (a token request).
      DpopCredential = Data.define(:token, :key)

      def self.dpop(token, key) = { 'Authorization' => DpopCredential.new(token:, key:) }

      # A solved proof of work for each challenge, as the `Kiosk-PoW` header carries them.
      def self.solve(challenges) = challenges.map { { challenge: it, nonce: PowSolver.for(it).solve(it) } }

      attr_reader :base_url

      def initialize(base_url:, pay_tolls: false, open_timeout: 10, read_timeout: 30)
        @base_url     = base_url.to_s.chomp('/')
        @pay_tolls    = pay_tolls
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def dpop(token, key) = self.class.dpop(token, key)

      def post_json(path, body = {}, headers = {}) = post(path, body, headers).then { [it.status, it.body] }

      def get_json(path, params = {}, headers = {}) = get(path, params, headers).then { [it.status, it.body] }

      def post(path, body = {}, headers = {}) = request(:post, path, body:, headers:)

      def get(path, params = {}, headers = {}) = request(:get, path, params:, headers:)

      def post_form(path, form, headers = {})
        request(:post, path, headers:) { it.set_form_data(form) }
      end

      def request(method, path, body: nil, params: nil, headers: {}, &form)
        klass = METHODS.fetch(method.to_s.downcase.to_sym) { raise ArgumentError, "unsupported HTTP method #{method.inspect}" }
        uri = request_uri(path, params)
        answer = deliver(klass, uri, body, headers, &form)
        challenges = toll_challenges(answer)
        return answer unless challenges

        proofs = self.class.solve(challenges)
        deliver(klass, uri, body, headers.merge('Kiosk-PoW' => JSON.generate(proofs)), &form).with(proofs: proofs.size)
      end

      private

      def request_uri(path, params)
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) if params&.any?
        uri
      end

      # The proof-of-work challenges of a toll this client solves, or nil.
      def toll_challenges(answer)
        return unless @pay_tolls && answer.status == 402 && answer.body.is_a?(Hash)

        challenges = answer.body['challenges']
        challenges if challenges.is_a?(Array) && challenges.any?
      end

      def deliver(klass, uri, body, headers, &)
        request = build(klass, uri, body, headers, &)
        begin
          answer = self.class.http_for(uri, open_timeout: @open_timeout, read_timeout: @read_timeout).request(request)
        rescue StandardError => e
          return Response.new(status: 0, body: { 'error' => e.class.name, 'detail' => e.message })
        end
        response(answer)
      end

      def build(klass, uri, body, headers)
        headers = { 'Content-Type' => 'application/json' }.merge(headers) unless body.nil?
        request = klass.new(uri, signed(headers, klass::METHOD, uri))
        request.body = JSON.generate(body) unless body.nil?
        yield request if block_given?
        request
      end

      # Each delivery signs its own DPoP proof, so a retry never reuses one.
      def signed(headers, method, uri)
        headers.each_with_object({}) do |(name, value), out|
          if value.is_a?(DpopCredential)
            out.merge!(Dpop.headers(value.token, value.key, method:, url: uri.to_s))
          else
            out[name] = value
          end
        end
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
