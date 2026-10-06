# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "kiosk"
require "kiosk/kyc_providers/prove/version"

module Kiosk
  module KycProviders
    # The Prove anonymizing KYC broker. The operator registers with the broker
    # once (an operator id, an intake secret and its callback host); the broker
    # then signs only the booleans the human confirmed, with `operator` set to
    # the operator the verification was opened for.
    class Prove < Base
      HOSTED = "https://kyc.demo.kiosk.tech"

      # The broker's claim id for an attribute name, where the two differ.
      CLAIM_IDS = { "licence_a" => "licence_category:A" }.freeze

      # The `iss` the broker signs with — `c.kyc_issuer`.
      def self.issuer = ENV.fetch("KIOSK_PROVE_ISSUER", HOSTED)

      def self.broker_url = ENV.fetch("KIOSK_PROVE_BROKER_URL", HOSTED)

      attr_reader :operator_id

      def initialize(operator_id:, intake_secret:, url: self.class.broker_url)
        raise ArgumentError, "the broker's intake secret for #{operator_id} is required" if intake_secret.to_s.empty?

        super()
        @operator_id = operator_id.to_s
        @secret      = intake_secret.to_s
        @intake      = URI.join(url.to_s.chomp("/") + "/", "verifications")
      end

      def open_verification(subject:, claims:, audience:, callback_url:)
        intake = post(
          operator_id: operator_id, callback_url: callback_url,
          requested_claims: claims.map { |name| CLAIM_IDS.fetch(name, name) },
          subject_handle: subject, audience: audience,
        )
        fields = intake.values_at("request_id", "verification_url", "nonce").map(&:to_s)
        raise Unavailable, "the KYC broker answered without request_id, verification_url and nonce" if fields.any?(&:empty?)

        %i[request_id verification_url nonce].zip(fields).to_h
      end

      def accepts?(payload) = payload["operator"].to_s == operator_id

      private

      def post(body)
        request = Net::HTTP::Post.new(@intake, "Content-Type" => "application/json",
                                               "Authorization" => "Bearer #{@secret}")
        request.body = JSON.generate(body)
        http = Net::HTTP.new(@intake.host, @intake.port)
        http.use_ssl = @intake.scheme == "https"
        http.open_timeout = http.read_timeout = 5

        response = http.request(request)
        raise Unavailable, "the KYC broker answered #{response.code}" unless response.code.to_i == 201

        parsed = JSON.parse(response.body)
        raise Unavailable, "the KYC broker answered a body that is not an object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise Unavailable, "the KYC broker answered a body that is not JSON"
      rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
        raise Unavailable, "the KYC broker could not be reached (#{e.class})"
      end
    end
  end
end
