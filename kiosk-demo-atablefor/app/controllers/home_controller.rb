# frozen_string_literal: true

# The provider's public root page. atablefor is api_only=false, and this
# controller inherits from ActionController::Base (not ::API) so it can render an
# HTML landing. Its job: make it OBVIOUS this is a Kiosk endpoint an AI assistant
# drives (the "point your assistant here / this speaks Kiosk" cue + the one-line
# prompt), NOT a human web-booking app — and show the PUBLIC, read-only
# reservations board so a viewer SEES an assistant's booking tied to its diner.
class HomeController < ActionController::Base
  # The home page (protocol-primary framing) + the reservations board rendered
  # inline. Reading the OWN tables, not telemetry; a refresh is enough.
  def index
    @tables_booked  = Booking.where(status: "confirmed").count
    @covers_seated  = Booking.where(status: "confirmed").sum(:party_size)
    @restaurants    = Restaurant.count
    @reservations   = upcoming_reservations

    # Set a Link header too, so a header-only agent finds the skill.
    # The url is `Kiosk.configuration.skill_url` — the VERSIONED cut this
    # operator pins, identical to the one `/.well-known/kiosk.json` carries
    # under `skill`, never the mutable skill.md alias. Derived rather than
    # restated so a cut is re-pinned in ONE place, the initializer.
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end

  # The board on its own URL. Same data; a standalone read-only page a viewer
  # can bookmark to watch reservations land under each diner's name.
  def reservations
    @reservations = upcoming_reservations
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end

  private

  # Upcoming confirmed reservations for the public board, spanning ALL
  # restaurants in the aggregator, joined to the diner's display name and to the
  # ACCOUNT UUID the pseudonym is derived from when there is no name.
  # The login address is deliberately NOT selected: this query feeds a page
  # anyone can fetch, and a column that never leaves the SELECT cannot be
  # published by a later reader of it. Read-only — the board never mutates
  # anything. Now onward, soonest first. Times are rendered in Europe/Lisbon (the
  # operator's locale) so the board reads in local wall-clock.
  def upcoming_reservations
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL).to_a
      SELECT
        r.name                                                             AS restaurant,
        r.neighborhood                                                     AS neighborhood,
        rt.label                                                           AS table_label,
        rt.deposit_eur                                                     AS deposit_eur,
        b.party_size                                                       AS party_size,
        to_char(b.seating_at AT TIME ZONE 'Europe/Lisbon', 'Dy DD Mon')    AS slot_day,
        to_char(b.seating_at AT TIME ZONE 'Europe/Lisbon', 'HH24:MI')      AS slot_time,
        u.display_name                                                     AS diner_name,
        u.id                                                               AS diner_account_id
      FROM bookings b
      JOIN restaurant_tables rt ON rt.id = b.restaurant_table_id
      JOIN restaurants r        ON r.id  = b.restaurant_id
      JOIN users u              ON u.id  = b.user_id
      WHERE b.status = 'confirmed'
        AND b.seating_at >= now()
      ORDER BY b.seating_at, r.name, rt.label
      LIMIT 50
    SQL
  end

  helper_method :board_diner_name

  # Public label for a reservation's diner: the seeded display name, else an
  # opaque `diner-<hex>` derived from the account uuid. {User.public_name} is
  # the whole rule and the argument for it lives there — this page is only one
  # of its readers.
  def board_diner_name(row)
    User.public_name(row["diner_name"], row["diner_account_id"])
  end
end
