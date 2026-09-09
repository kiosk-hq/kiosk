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
  # atablefor's handlers do not write SQL, yet this fragment deliberately stays
  # a SQL predicate rather than a Ruby comparison, for the reason the philslist
  # pilot settled (see Listing#owned_by_current_principal).
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

  # `seating_at` as EVERY verb of this demo publishes it, and the pin is two
  # separate decisions that were being made by one line.
  #
  # THE TYPE. Not cosmetic: the column is `timestamptz`, and the raw `execute`
  # this verb used returned PG's decoded value as a plain Ruby `Time`, which
  # `as_json` renders "…T18:00:00.000+00:00". ActiveRecord hands back an
  # `ActiveSupport::TimeWithZone`, which renders the SAME instant as "…Z", with
  # a millisecond field the encoder's `time_precision` sets. Both are valid ISO
  # 8601 and mean the same moment, but they are different bytes on a published
  # wire, so the form is pinned here rather than left to whichever type the
  # persistence layer happens to return — and a String is the strongest pin
  # there is, identical here, in CI and on a box in another zone.
  #
  # THE CLOCK, chosen here rather than inherited. All THREE verbs that publish a
  # booking instant go through this one writer — `availability` offers the
  # seating, the `book_table` confirmation answers it, `my_bookings` reads it
  # back — so the three answer one booking in one spelling. Two offsets under
  # output schemas that describe the field identically would be one instant in
  # two spellings.
  #
  # AND IT IS THE RESTAURANT'S CLOCK, handed in, not this aggregator's. The
  # table is where the table is, and an aggregator may list places in more than
  # one city; the caller of this method knows which restaurant a row is about
  # and so passes its zone. The default is the origin's, for the one caller that
  # has no restaurant in hand: a published example.
  def self.publish_instant(time, zone = Seatings.default_zone)
    time&.in_time_zone(zone)&.iso8601
  end
end
