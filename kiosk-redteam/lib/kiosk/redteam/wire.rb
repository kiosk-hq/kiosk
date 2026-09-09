# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Kiosk
  module Redteam
    # The raw wire — for the attacks {Client} deliberately cannot express.
    #
    # {Client} speaks the wire AS A PRINCIPAL: it registers, settles the toll,
    # and sends query / run / pay carrying a bearer it minted. A whole class of
    # attack is about the REQUEST rather than about the principal sending it:
    # a forged or absent `Authorization`, a verb name nobody registered, the
    # wrong HTTP method at a real verb's path, an assertion on a response
    # HEADER (`Allow:`) rather than on its body. Those need an arbitrary method
    # at an arbitrary path with arbitrary headers, and that is what this is.
    #
    #   wire = Kiosk::Redteam::Wire.new(base_url: "http://127.0.0.1:3006")
    #   status, doc = wire.post_json("/kiosk/edit_listing", { listing_id: "junk" },
    #                                Kiosk::Redteam::Wire.bearer(token))
    #
    # == Why an unparseable body is not an exception
    #
    # {#post_json} and {#get_json} answer `[status, parsed_body]` and never
    # raise on a body that is not JSON. An attack that provokes an HTML error
    # page, a proxy's plain-text refusal or an empty body has to be ASSERTED
    # on, not crashed on — a battery that dies on the wrong answer reports
    # nothing about the right one — so an unparseable body reads as `{}` and
    # the status carries the verdict. The raw bytes are still available on
    # {Raw#raw_body} for a leak scan, which is the one assertion that must see
    # what was actually sent rather than what parsed.
    #
    # == Why a connection error is status 0
    #
    # The same sentinel {Response} uses. An origin that refused the connection
    # has refused nothing about the attack, so a battery must never be able to
    # read it as a block: 0 is outside every status a scenario admits, and
    # {Kiosk::Redteam.blocked?} answers false for it by name.
    class Wire
      # One answer off the wire, with the parts an attack asserts on.
      #
      # @!attribute status   [Integer] HTTP status; 0 for a connection error
      # @!attribute headers  [Hash{String=>String}] response headers, keys downcased
      # @!attribute body     [Object] the parsed JSON body, or `{}` when it did not parse
      # @!attribute raw_body [String] the bytes exactly as they arrived
      Raw = Data.define(:status, :headers, :body, :raw_body) do
        # Header lookup, case-insensitively, the way `Net::HTTPResponse#[]`
        # answers — so a beat that moves here does not have to learn a second
        # spelling for `res["allow"]`.
        #
        # @param name [String, Symbol]
        # @return [String, nil]
        def [](name)
          headers[name.to_s.downcase]
        end
      end

      # An `Authorization: Bearer …` header hash.
      #
      # A module function as well as an instance method because half the beats
      # that need it build the header for a token they forged rather than for
      # one an origin minted, and those have no wire in hand yet.
      #
      # @param token [String]
      # @return [Hash{String=>String}]
      def self.bearer(token)
        { "Authorization" => "Bearer #{token}" }
      end

      # @return [String] the origin under attack, without a trailing slash
      attr_reader :base_url

      # @param base_url [String] e.g. "http://127.0.0.1:3006"
      # @param open_timeout [Integer] seconds
      # @param read_timeout [Integer] seconds
      def initialize(base_url:, open_timeout: 10, read_timeout: 30)
        @base_url     = base_url.to_s.chomp("/")
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      # @param token [String]
      # @return [Hash{String=>String}]
      def bearer(token) = self.class.bearer(token)

      # POST a JSON body.
      #
      # @param path    [String] absolute path on the origin, e.g. "/kiosk/post_listing"
      # @param body    [Object] serialised with `JSON.generate`
      # @param headers [Hash]   merged over `Content-Type: application/json`
      # @return [Array(Integer, Object)] status and parsed body
      def post_json(path, body = {}, headers = {})
        raw = post(path, body, headers)
        [raw.status, raw.body]
      end

      # GET with query-string parameters.
      #
      # @param path    [String]
      # @param params  [Hash] form-encoded onto the query string
      # @param headers [Hash]
      # @return [Array(Integer, Object)] status and parsed body
      def get_json(path, params = {}, headers = {})
        raw = get(path, params, headers)
        [raw.status, raw.body]
      end

      # @return [Raw]
      def post(path, body = {}, headers = {})
        request(:post, path, body: body, headers: headers)
      end

      # @return [Raw]
      def get(path, params = {}, headers = {})
        request(:get, path, params: params, headers: headers)
      end

      # Any method at any path, with the whole answer returned.
      #
      # This is the method the wire-shaped beats want: a `MethodMismatch` beat
      # asserts on `Allow:`, which is a header, and a leak scan asserts on the
      # bytes, which is neither the status nor the parsed body.
      #
      # @param method  [Symbol] :get, :post, :put, :patch, :delete, :head, :options
      # @param path    [String]
      # @param body    [Object, nil] JSON-encoded when not nil
      # @param params  [Hash, nil] form-encoded onto the query string
      # @param headers [Hash]
      # @return [Raw]
      def request(method, path, body: nil, params: nil, headers: {})
        klass = NET_HTTP_CLASSES.fetch(method.to_s.downcase.to_sym) do
          raise ArgumentError, "unsupported HTTP method #{method.inspect}"
        end
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) if params && !params.empty?
        hdrs = body.nil? ? headers : { "Content-Type" => "application/json" }.merge(headers)
        req  = klass.new(uri, hdrs)
        req.body = JSON.generate(body) unless body.nil?

        # The rescue covers the CALL and nothing else, deliberately. A wider
        # one swallows a mistake in the beat — a method this class cannot
        # spell, a body that will not serialise — and renders it as status 0,
        # which reads as "the origin was unreachable". A harness whose own bugs
        # look like the provider being down is worse than one that crashes.
        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl      = uri.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          wrap(http.request(req))
        rescue StandardError => e
          # Status 0, never an exception and never a status a scenario admits:
          # an origin that could not be reached has refused nothing.
          Raw.new(status: 0, headers: {}, body: { "error" => e.class.name, "detail" => e.message },
                  raw_body: "")
        end
      end

      # The methods a hostile probe here has ever needed, named rather than
      # derived, because `Net::HTTP` spells each one as its own class and an
      # unsupported one must say so instead of raising `NoMethodError` from
      # somewhere deeper.
      NET_HTTP_CLASSES = {
        get:     Net::HTTP::Get,
        post:    Net::HTTP::Post,
        put:     Net::HTTP::Put,
        patch:   Net::HTTP::Patch,
        delete:  Net::HTTP::Delete,
        head:    Net::HTTP::Head,
        options: Net::HTTP::Options,
      }.freeze

      private

      def wrap(res)
        raw_body = res.body.to_s
        parsed   = begin
          JSON.parse(raw_body)
        rescue StandardError
          {}
        end
        headers = {}
        res.each_header { |k, v| headers[k.to_s.downcase] = v }
        Raw.new(status: res.code.to_i, headers: headers, body: parsed, raw_body: raw_body)
      end
    end
  end
end
