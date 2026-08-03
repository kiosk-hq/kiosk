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
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end

  # The board on its own URL. Same data; a standalone read-only page a viewer
  # can bookmark to watch listings land under each poster's name.
  def listings
    @board_listings = open_board_listings
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
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

  # Public label for a listing's poster: the account's masked email local-part
  # (philslist accounts carry no display name), else a headless placeholder.
  # Both of Alice's household assistants post under the SAME account, so both of
  # their listings read under one poster here — the household made visible.
  def board_poster_name(listing)
    email = listing.owner&.email.to_s
    if email.include?("@")
      local = email.split("@").first
      return local.length <= 2 ? local : "#{local[0, 2]}#{'•' * (local.length - 2)}"
    end
    "Assistant account"
  end
end
