# frozen_string_literal: true

# A room-night hold on one room type. `status` moves reserved → confirmed once a
# settlement referencing this booking exists; `confirmation_code` is the
# reference the guest gives at the desk and is written by the same UPDATE that
# confirms, never minted for a response.
class Booking < ApplicationRecord
  RESERVED  = "reserved"
  CONFIRMED = "confirmed"
  # The property said no. A real desk sometimes does, minutes after the money
  # arrived, and this demo says so at a rate it publishes rather than pretending
  # every booking is accepted.
  DECLINED  = "declined"
  # The statuses that still HOLD the room-night. A cancelled or expired booking
  # frees its nights again, which is why the overlap exclusion — here and in the
  # `bookings_no_overlapping_room_nights` EXCLUDE constraint — is scoped to
  # these two and not to every row.
  LIVE = [RESERVED, CONFIRMED].freeze

  # ── The PAYMENT lifecycle, orthogonal to `status` above ────────────────────
  # `status` is the room-night; this is the money. A booking is `unpaid` until a
  # /pay CLAIMS it (`paying`, an atomic compare-and-set taken BEFORE the cashier
  # check and the capture), and `paid` the instant the capture returns — a hair
  # before the engine writes its settlement row. That ordering is the whole
  # point: protocol.md §11.6 anchors published paid state to the CAPTURE, never
  # to the settlement record.
  UNPAID = "unpaid"
  PAYING = "paying"
  PAID   = "paid"
  # The money went back. Kept as a payment state rather than as the absence of
  # one, because «never paid» and «paid and returned» are different facts and an
  # assistant telling its human about the second must not read the first.
  REFUNDED = "refunded"

  # What `my_bookings` publishes, and the three answers §11.6 allows. `PENDING`
  # is the third state the spec REQUIRES: a capture has been started and its
  # outcome is not known, which is neither paid nor not-paid, and which an
  # assistant must never read as a licence to sign a fresh mandate chain.
  STATE_UNPAID  = "unpaid"
  STATE_PENDING = "pending"
  STATE_PAID    = "paid"

  belongs_to :user
  belongs_to :property
  belongs_to :room_type

  scope :live, -> { where(status: LIVE) }

  # ── WHAT THE EVENT SURFACE READS ───────────────────────────────────────────
  # The isolation predicate below resolves the principal from a Postgres GUC
  # set per request. A standing subscription is re-authorised on a timer, with
  # no request and no GUC, so this twin takes the account as an argument. It is
  # NOT a second copy of the gate: the gate is what a VERB passes through, and
  # this answers a different question — may this account hold a feed about this
  # booking.
  #
  # @return [Boolean]
  def self.readable_by?(booking_id, user_id)
    return false if booking_id.to_s.empty? || user_id.to_s.empty?

    where(id: booking_id, user_id: user_id).exists?
  end

  # ── THE isolation predicate ────────────────────────────────────────────────
  # The one predicate in this demo deliberately written as SQL rather than as a
  # Ruby comparison. Why:
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
    # Off the wire there is no principal, so this predicate would be `= NULL`
    # and answer nothing at all; refuse instead of returning a plausible zero.
    Kiosk::Server::SessionContext.require_open!
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }

  # ── THE room-night invariant, written ONCE ─────────────────────────────────
  # Nights are HALF-OPEN: a checkout day is the next guest's check-in day, so two
  # stays clash iff `check_in < other.check_out AND check_out > other.check_in`.
  # Three callers need exactly this predicate — `availability`, `hotel_detail`'s
  # dated form, and `reserve_room`'s in-transaction pre-check — and every extra
  # spelling is another chance to drift away from the `daterange(check_in,
  # check_out) WITH &&` the database EXCLUDE constraint enforces. So it is one
  # scope, and the abutting-nights positive control in the redteam battery is
  # what proves it did not get over-broad.
  #
  # The two bounds are BOUND VALUES, so a Date (or a date string) is quoted by
  # the adapter rather than interpolated.
  scope :overlapping, lambda { |check_in, check_out|
    where(arel_table[:check_in].lt(check_out))
      .where(arel_table[:check_out].gt(check_in))
  }

  # ── THE settled-cart containment, correlated to the row being selected ─────
  #
  # Why there are TWO spellings of one predicate, and why this one is a frozen
  # SQL literal where {CartMandate.referencing} is Arel. That scope binds a
  # SINGLE, CALLER-SUPPLIED booking id, so the value must be quoted by the
  # adapter. This one binds NO value at all: it correlates the cart's line_items
  # against `bookings.id` — the column of whichever row the enclosing SELECT is
  # looking at — which is what lets `my_bookings` answer "paid?" for a whole
  # LIST in one statement instead of one query per row. Nothing here is
  # caller-controlled, the same exemption `owned_by_current_principal` rests on.
  SETTLED_CART_REFERENCES_THIS_ROW = Arel.sql(
    "kiosk.cart_mandates.line_items @> " \
    "json_build_array(json_build_object('booking_id', bookings.id::text))::jsonb",
  ).freeze

  # The settlements — OF THE RELATION THE CALLER IS ENTITLED TO SEE — whose cart
  # references the booking row being selected. `my_bookings` passes
  # `Settlement.of_current_principal`; the parameter is what keeps the
  # CONTAINMENT one expression while the AUTHORITY stays the caller's.
  #
  # @param settlements [ActiveRecord::Relation] settlements this caller may read
  def self.settled_flag(settlements)
    settlements.joins(:cart_mandate)
               .where(SETTLED_CART_REFERENCES_THIS_ROW)
               .select(Arel.sql("1"))
               .arel
               .exists
  end

  # ── The one place "has money moved for this booking" is decided ────────────
  #
  # protocol.md §11.6: an operator MUST NOT publish *not paid* while a capture
  # may still be outstanding, and MUST offer a third state distinct from both.
  # So the answer is read from the CAPTURE-anchored marker FIRST and from the
  # settlement row only as a second, confirming witness:
  #
  #   paid    — the capture returned (`payment_status = 'paid'`) OR a settlement
  #             row exists. Either witness alone is enough; the first one lands
  #             before the second, and the gap between them is the whole bug.
  #   pending — a capture was CLAIMED and has not resolved. Not paid, not
  #             unpaid. An assistant that sees this must reconcile or stop —
  #             never sign a fresh chain.
  #   unpaid  — no capture has ever been claimed for this booking. This is the
  #             ONLY positive, unambiguous "not paid" hoteling ever publishes,
  #             and the only one that makes a fresh mandate chain correct.
  #
  # @param payment_status [String] the row's capture-anchored marker
  # @param settled [Boolean] whether a settlement the caller may see references it
  def self.payment_state(payment_status, settled)
    return STATE_PAID    if payment_status == PAID || settled
    return STATE_PENDING if payment_status == PAYING

    STATE_UNPAID
  end
end
