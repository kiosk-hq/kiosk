# frozen_string_literal: true

# The provider's public root page.
# philslist tells a human/agent what this demo is, shows live DOMAIN activity
# (real listing counts) AND the PUBLIC classifieds board — classifieds are
# public by nature, so a viewer SEES a listing an assistant posts over the wire
# appear here (title · category · €price · poster), while owner-scoped isolation
# still governs who may EDIT it. Both doors are shown; Devise needs this as its
# post-sign-in destination too.
class HomeController < ApplicationController
  def index
    # Cheap domain counts, rendered server-side on page load (a refresh is
    # enough — no JS polling). These read philslist's OWN tables.
    @listings_posted = Listing.count
    @open_listings   = Listing.where(status: "open").count
    @closed_listings = Listing.where(status: "closed").count
    @categories      = Category.count

    # The public board itself: current OPEN listings across ALL owners, newest
    # first. Reading the OWN tables — a refresh shows a freshly
    # posted listing. Same read `browse_listings` exposes over the wire.
    @board_listings = Listing.on_board

    # Set a Link header too, so a header-only agent finds the skill.
    # The url is `Kiosk.configuration.skill_url` — the VERSIONED cut this
    # operator pins, identical to the one `/.well-known/kiosk.json` carries
    # under `skill`, never the mutable skill.md alias. Derived rather than
    # restated so a cut is re-pinned in ONE place, the initializer.
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end

  # The board on its own URL. Same data; a standalone read-only page a viewer
  # can bookmark to watch listings land under each poster's name.
  def listings
    @board_listings = Listing.on_board
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end
end
