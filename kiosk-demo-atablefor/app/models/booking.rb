# frozen_string_literal: true

# A table reservation: one principal holding one physical table for one seating
# instant. `status` is the whole lifecycle ('confirmed' | 'cancelled'), and it is
# load-bearing rather than decorative — the UNIQUE PARTIAL INDEX
# `idx_bookings_confirmed_table_seating` covers (restaurant_table_id, seating_at)
# only WHERE status = 'confirmed', so cancelling a booking is what frees the
# (table, seating) for someone else.
class Booking < ApplicationRecord
  CONFIRMED = "confirmed"
  CANCELLED = "cancelled"

  belongs_to :user
  belongs_to :restaurant
  belongs_to :restaurant_table

  # The set the unique partial index is defined over. Writing it once means the
  # availability subtraction, the double-booking pre-check and the cancel guard
  # cannot drift from the index that is the real authority.
  scope :confirmed, -> { where(status: CONFIRMED) }

  # ── THE isolation predicate ────────────────────────────────────────────────
  # When atablefor's handlers stopped writing SQL (K-654) this is the fragment
  # that deliberately did NOT become a Ruby comparison, for the reason the
  # philslist pilot settled (see Listing#owned_by_current_principal).
  #
  # `kiosk.current_user_id()` is a STABLE Postgres function reading the
  # transaction-local GUC `app.current_user_id`, which kiosk-server's
  # SessionContext sets with `SET LOCAL` — from the identity the wire resolved,
  # inside the very transaction the handler runs in — and which evaporates at
  # COMMIT. The mixin's `kiosk_identity` carries the same principal and would be
  # just as unforgeable; what it would cost is the part that generalises. Spec §7
  # makes DB-enforced identity scoping a MUST, and this is the seam where the
  # app-layer predicate and the optional DB-layer RLS policy are literally the
  # same expression. A demo is the reference other operators copy.
  #
  # `Arel.sql` over a frozen literal rather than an interpolated string: there is
  # no caller-controlled value anywhere in this fragment. That is what makes it
  # exempt from the no-raw-SQL rule rather than an exception to it.
  scope :owned_by_current_principal, lambda {
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }

  # `seating_at` as `my_bookings` has always published it. Not cosmetic: the
  # column is `timestamptz`, and the raw `execute` this verb used returned PG's
  # decoded value as a plain Ruby `Time` carrying a +00:00 offset, which
  # `as_json` renders "…T18:00:00.000+00:00". ActiveRecord hands back an
  # `ActiveSupport::TimeWithZone`, which renders the SAME instant as "…Z".
  # Both are valid ISO 8601 and mean the same moment, but they are different
  # bytes on a published wire, so the published form is pinned here rather than
  # left to whichever type the persistence layer happens to return.
  def self.publish_instant(time)
    time&.utc&.localtime("+00:00")
  end
end
