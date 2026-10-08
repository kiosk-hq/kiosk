# frozen_string_literal: true

# The page a rental verb's `unlock_url` opens: the QR of that same URL, the
# token and the vehicle. It shows only what the URL carries — the token is the
# bearer, so the page looks nothing up and grants nothing the URL did not.
class UnlockController < ApplicationController
  layout "home"

  def show
    @scooter_code = params.expect(:scooter)
    @rental_token = params.expect(:rt)
    @qr_svg = UnlockLink.svg(
      UnlockLink.url(origin: request.base_url, scooter_code: @scooter_code, rental_token: @rental_token),
    )
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end
end
