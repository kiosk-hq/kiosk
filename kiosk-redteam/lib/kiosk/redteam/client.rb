# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "jwt"

module Kiosk
  module Redteam
    # HTTP driver for the Kiosk provider API.
    #
    # Covers the full agent flow:
    #   register (+ SHA256 PoW solving) → kyc → query / run → pay
    #
    # Two registration entry points:
    #   - {#register_raw} — always returns a {Response}; use in scenarios that
    #     assert a rejection (e.g. RegistrationWithoutPow).
    #   - {#register!}    — returns a {Principal} on HTTP 201; raises otherwise.
    #
    # Wire formats mirror kiosk-demo-skooti/rental_flow.rb and
    # kiosk-demo-foodelivery/order_flow.rb exactly.
    class Client
      # Raised by {#register!} when the server does not respond 201.
      class RegistrationError < StandardError; end

      def initialize(base_url:)
        @base_url = base_url.chomp("/")
      end

      # ── Registration ──────────────────────────────────────────────────────

      # Low-level registration — always returns a {Response} regardless of
      # the HTTP status.  Use this in scenarios that expect a rejection
      # (e.g. RegistrationWithoutPow).
      #
      # @param name           [String]           agent display name
      # @param role           [String]           "customer" (default)
      # @param pow_difficulty [Integer]          required leading-zero bits (0 = none)
      # @param pow            [:solve, :skip, String]
      #   :solve  — auto-solve PoW when pow_difficulty > 0 (omit field when 0)
      #   :skip   — never include the pow field (test missing-proof)
      #   String  — send this exact value verbatim (test bad-proof)
      # @return [Response]
      def register_raw(name:, role: "customer", pow_difficulty: 0, pow: :solve)
        response, _key = build_register(name:, role:, pow_difficulty:, pow:)
        response
      end

      # High-level registration — returns a {Principal} on HTTP 201 or raises.
      #
      # @param (see #register_raw)
      # @return [Principal]
      # @raise [RegistrationError] when the server responds with a non-201 status
      def register!(name:, role: "customer", pow_difficulty: 0, pow: :solve)
        response, key = build_register(name:, role:, pow_difficulty:, pow:)
        unless response.status == 201
          raise RegistrationError,
            "register! expected 201, got #{response.status}: #{response.body.inspect}"
        end
        Principal.new(
          agent_id: response.body.fetch("agent_id"),
          user_id:  response.body.fetch("user_id"),
          token:    response.body.fetch("access_token"),
          rsa_key:  key,
        )
      end

      # ── KYC ───────────────────────────────────────────────────────────────

      # Submit a KYC attestation JWS for the given principal.
      #
      # @param principal       [Principal]
      # @param attestation_jws [String] pre-built JWS from the KYC issuer
      # @return [Response]
      def kyc(principal, attestation_jws:)
        post_json(
          "/kiosk/agents/kyc",
          { kyc_jws: attestation_jws },
          bearer: principal.token,
        )
      end

      # ── Exec verbs ────────────────────────────────────────────────────────

      # Execute a named query (read-only).
      #
      # @param principal [Principal]
      # @param name      [String]  query name registered by the provider
      # @param params    [Hash]    additional query parameters
      # @return [Response]
      def query(principal, name:, **params)
        post_json(
          "/kiosk/exec",
          { command: "query", body: { name: name }.merge(params) },
          bearer: principal.token,
        )
      end

      # Execute a named action (write).
      #
      # @param principal [Principal]
      # @param name      [String] action name registered by the provider
      # @param args      [Hash]   action arguments
      # @return [Response]
      def run(principal, name:, **args)
        post_json(
          "/kiosk/exec",
          { command: "run", body: { name: name }.merge(args) },
          bearer: principal.token,
        )
      end

      # Sign and POST a pay command with RS256-signed intent + cart mandates.
      #
      # The mandates are signed with the principal's RSA private key so the
      # provider can verify the principal authored them.  Use {#sign_mandate}
      # directly to craft forged / tampered mandates.
      #
      # @param principal [Principal]
      # @param intent    [Hash] intent mandate payload
      # @param cart      [Hash] cart mandate payload
      # @return [Response]
      def pay(principal, intent:, cart:)
        post_json(
          "/kiosk/exec",
          {
            command: "pay",
            body: {
              intent_mandate_jws: sign_mandate(principal, intent),
              cart_mandate_jws:   sign_mandate(principal, cart),
            },
          },
          bearer: principal.token,
        )
      end

      # Sign an arbitrary payload as an RS256 JWS using the principal's private
      # RSA key.  Exposed so scenarios can craft forged / tampered mandates.
      #
      # @param principal [Principal]
      # @param payload   [Hash] JWT claims
      # @return [String] compact JWS (header.payload.signature)
      def sign_mandate(principal, payload)
        JWT.encode(payload, principal.rsa_key, "RS256")
      end

      private

      # Shared implementation for both #register_raw and #register!.
      # Returns [Response, OpenSSL::PKey::RSA] — the key is discarded by
      # register_raw (it was for a rejected registration) but captured by
      # register! to build the Principal.
      def build_register(name:, role:, pow_difficulty:, pow:)
        key = OpenSSL::PKey::RSA.generate(2048)
        pem = key.public_key.to_pem
        pow_value = resolve_pow(pem, pow, pow_difficulty)

        body = { name: name, public_key: pem, role: role }
        body[:pow] = pow_value unless pow_value.nil?

        [post_json("/kiosk/agents/register", body), key]
      end

      # Resolve the pow field value given the pow strategy.
      #
      # @return [String, nil] value to send as the "pow" field, or nil to omit it
      def resolve_pow(pem, pow, difficulty)
        case pow
        when :skip
          nil
        when :solve
          return nil unless difficulty > 0

          n = 0
          n += 1 until leading_zero_bits(Digest::SHA256.digest("#{pem}.#{n}")) >= difficulty
          n.to_s
        else
          pow.to_s   # verbatim String (e.g. bad-proof test)
        end
      end

      # Count leading zero bits in a binary digest string.
      #
      # Copied EXACTLY from kiosk-demo-skooti/rental_flow.rb:67-82, which in
      # turn mirrors Kiosk::Server::ProofOfWork.leading_zero_bits.
      # Do not change without updating both sources.
      #
      # @param bytes [String] raw binary bytes (e.g. 32-byte SHA256 output)
      # @return [Integer]
      def leading_zero_bits(bytes)
        return 0 if bytes.empty?

        count = 0
        bytes.each_byte do |b|
          if b == 0
            count += 8
          else
            bit = 7
            bit -= 1 while bit >= 0 && b[bit] == 0
            count += (7 - bit)
            break
          end
        end
        count
      end

      # POST JSON to the given path; returns a {Response}.
      #
      # @param path   [String]      URL path (including leading slash)
      # @param body   [Hash]        request body (serialised to JSON)
      # @param bearer [String, nil] Bearer token for Authorization header
      # @return [Response]
      def post_json(path, body, bearer: nil)
        uri = URI("#{@base_url}#{path}")
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{bearer}" if bearer

        req = Net::HTTP::Post.new(uri, headers)
        req.body = JSON.generate(body)

        http = Net::HTTP.new(uri.host, uri.port)
        res  = http.request(req)

        parsed = begin
          JSON.parse(res.body)
        rescue JSON::ParserError
          {}
        end

        Response.new(status: res.code.to_i, body: parsed)
      end
    end
  end
end
