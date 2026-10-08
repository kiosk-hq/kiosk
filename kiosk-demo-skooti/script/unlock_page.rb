# frozen_string_literal: true

require "net/http"
require "uri"
require "kiosk/redteam/wire"
require_relative "../app/services/unlock_link"

# GETs the `unlock_url` a rental verb answered, as the human's browser would,
# and reports what the page shows: the status, whether it carries the QR of
# that exact URL, and whether it shows the token the verb answered beside it.
def unlock_page_check(unlock_url, rental_token)
  return { status: nil, qr: false, token: false } unless unlock_url

  uri = URI(unlock_url)
  res = Kiosk::Redteam::Wire.http_for(uri).request(Net::HTTP::Get.new(uri))
  body = res.body.to_s
  { status: res.code.to_i, qr: body.include?(UnlockLink.svg(unlock_url)), token: body.include?(rental_token.to_s) }
end
