# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# CallbackPoster — the broker → operator leg (design §4.8). On the human's
# approve, the broker mints the signed anonymized claim and POSTs it to the
# request's callback_url as `{ request_id, kyc_jws, nonce }` — a compact JWS and
# an echo of the request's nonce.
#
# callback_url was already validated at intake against the operator's
# allow-listed host (OperatorRegistry.callback_allowed? — the SSRF guard), so
# this never posts to an arbitrary host.
module CallbackPoster
  module_function

  # POST the signed claim to the operator's callback. Returns the HTTP status
  # (Integer), or nil on a transport error — delivery is best-effort here (the
  # broker still records the local decision, and the agent polls anyway).
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
