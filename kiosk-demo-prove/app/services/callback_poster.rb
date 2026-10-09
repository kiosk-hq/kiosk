# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# Posts an approved claim to the operator's callback, a host the intake
# already checked against the operator's registration.
module CallbackPoster
  module_function

  # The callback's HTTP status, or nil when it could not be reached.
  def deliver(callback_url:, request_id:, kyc_jws:, nonce:)
    uri = URI.parse(callback_url.to_s)
    body = JSON.generate(request_id: request_id, kyc_jws: kyc_jws, nonce: nonce)

    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = body

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 5

    res = http.request(req)
    res.code.to_i
  rescue StandardError => e
    Rails.logger.warn("[kiosk-demo-prove] callback POST to #{callback_url} failed: #{e.class}: #{e.message}")
    nil
  end
end
