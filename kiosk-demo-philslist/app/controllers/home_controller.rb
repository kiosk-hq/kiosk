# frozen_string_literal: true

# The provider's public root page (replaces the former inline proc root).
# philslist is api-only in spirit (no public HTML listings index, by design),
# but the root still needs to tell a human/agent what this demo is, show live
# DOMAIN activity (real listing counts), and point at both doors. Devise needs
# this as its post-sign-in destination too.
class HomeController < ApplicationController
  # Self-contained full-HTML page; the app ships no application layout.
  layout false

  def index
    # Cheap domain counts, rendered server-side on page load (a refresh is
    # enough — no JS polling). These read philslist's OWN tables, not telemetry.
    @listings_posted = Listing.count
    @open_listings   = Listing.where(status: "open").count
    @closed_listings = Listing.where(status: "closed").count
    @categories      = Category.count

    # Set a Link header too, so a header-only agent finds the skill.
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end
end
