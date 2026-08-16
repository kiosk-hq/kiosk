# frozen_string_literal: true

# A room-night hold on one room type. `status` moves reserved → confirmed once a
# settlement referencing this booking exists; `confirmation_code` is the
# reference the guest gives at the desk and is written by the same UPDATE that
# confirms (K-698), never minted for a response.
class Booking < ApplicationRecord
  RESERVED  = "reserved"
  CONFIRMED = "confirmed"
  # The statuses that still HOLD the room-night. A cancelled or expired booking
  # frees its nights again, which is why the overlap exclusion — here and in the
  # `bookings_no_overlapping_room_nights` EXCLUDE constraint — is scoped to
  # these two and not to every row.
  LIVE = [RESERVED, CONFIRMED].freeze

  belongs_to :user
  belongs_to :property
  belongs_to :room_type

  scope :live, -> { where(status: LIVE) }

  # ── THE isolation predicate ────────────────────────────────────────────────
  # When hoteling's handlers stopped writing SQL (K-654) this is the one fragment
  # that deliberately did NOT become a Ruby comparison, for the reason the
  # philslist pilot settled (see Listing#owned_by_current_principal).
  #
  # `kiosk.current_user_id()` is a STABLE Postgres function reading the
  # transaction-local GUC `app.current_user_id`, which kiosk-server's
  # SessionContext sets with `SET LOCAL` — from the identity the wire resolved,
  # inside the very transaction the request runs in — and which evaporates at
  # COMMIT. A `where(user_id: <a ruby value>)` would be just as unforgeable here;
  # what it would cost is the part that generalises. Spec §7 makes DB-enforced
  # identity scoping a MUST, and this is the seam where the app-layer predicate
  # and the optional DB-layer RLS policy are literally the same expression. A
  # demo is the reference other operators copy.
  #
  # `Arel.sql` over a frozen literal rather than an interpolated string: there is
  # no caller-controlled value anywhere in this fragment. That is what makes it
  # exempt from the no-raw-SQL rule rather than an exception to it.
  scope :owned_by_current_principal, lambda {
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }

  # ── THE room-night invariant (K-690), written ONCE ─────────────────────────
  # Nights are HALF-OPEN: a checkout day is the next guest's check-in day, so two
  # stays clash iff `check_in < other.check_out AND check_out > other.check_in`.
  # Three callers need exactly this predicate and used to spell it three times in
  # SQL — `availability`, `hotel_detail`'s dated form, and `reserve_room`'s
  # in-transaction pre-check — which is three chances for one of them to drift
  # away from the `daterange(check_in, check_out) WITH &&` the database EXCLUDE
  # constraint enforces. It is one scope now, and the abutting-nights positive
  # control in the redteam battery is what proves it did not get over-broad.
  #
  # The two bounds are BOUND VALUES, so a Date (or a date string) is quoted by
  # the adapter rather than interpolated.
  scope :overlapping, lambda { |check_in, check_out|
    where(arel_table[:check_in].lt(check_out))
      .where(arel_table[:check_out].gt(check_in))
  }
end
