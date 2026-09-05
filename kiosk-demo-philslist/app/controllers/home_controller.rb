# frozen_string_literal: true

# The provider's public root page (replaces the former inline proc root).
# philslist tells a human/agent what this demo is, shows live DOMAIN activity
# (real listing counts) AND the PUBLIC classifieds board — classifieds are
# public by nature, so a viewer SEES a listing an assistant posts over the wire
# appear here (title · category · €price · poster), while owner-scoped isolation
# still governs who may EDIT it. Both doors are shown; Devise needs this as its
# post-sign-in destination too.
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

    # The public board itself: current OPEN listings across ALL owners, newest
    # first. Reading the OWN tables (not telemetry) — a refresh shows a freshly
    # posted listing. Same read `browse_listings` exposes over the wire.
    @board_listings = open_board_listings

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
    @board_listings = open_board_listings
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end

  private

  # Open listings for the public board, joined to the category and the poster's
  # handle. Read-only — the board never mutates anything. Newest first, capped.
  def open_board_listings
    Listing
      .where(status: "open")
      .includes(:category, :owner)
      .order(created_at: :desc, id: :asc)
      .limit(50)
  end

  helper_method :board_poster_name

  # Public label for a listing's poster — THE SAME PSEUDONYM THE WIRE PUBLISHES,
  # so the page and `browse_listings` cannot come to disagree about who a seller
  # is. NOT a masked email local-part (`al•••`), which is a thin mask: against a
  # known domain it leaks two characters of a real address and confirms which
  # addresses hold accounts. {User.public_handle} is derived from the account
  # UUID and reveals nothing.
  #
  # Both of Alice's household assistants post under the SAME account, so both of
  # their listings read under one handle here — the household made visible, and
  # the reason the handle is per-seller rather than per-listing.
  def board_poster_name(listing)
    owner = listing.owner
    return "an unknown account" if owner.nil?

    owner.public_handle
  end
end
