# frozen_string_literal: true

# The provider's public storefront. Its only Kiosk-specific job is to ADVERTISE
# the agent affordance: a visible "Agents → Kiosk here" hook + a machine-readable
# <link rel="kiosk"> so an assistant scanning the page discovers it can transact.
class HomeController < ActionController::Base
  def index
    # Set a Link header too, so a header-only agent finds the well-known.
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end
end
