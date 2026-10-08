# frozen_string_literal: true

require "cgi"
require "rqrcode"

# The unlock URL for one rental, and its QR. The same URL is the App Clip's
# launch link, so its shape is the clip's contract: `scooter` and `rt` in the
# query, which is where the clip reads them.
module UnlockLink
  PATH = "/unlock"

  module_function

  def url(origin:, scooter_code:, rental_token:)
    "#{origin.to_s.chomp("/")}#{PATH}?scooter=#{CGI.escape(scooter_code)}&rt=#{CGI.escape(rental_token)}"
  end

  def qr(url) = RQRCode::QRCode.new(url)

  def svg(url)
    qr(url).as_svg(offset: 0, color: "000", shape_rendering: "crispEdges", module_size: 6, viewbox: true)
  end
end
