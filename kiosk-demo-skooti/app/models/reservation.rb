# frozen_string_literal: true

# A hold on ONE fleet vehicle for one principal. `status` moves
# reserved → active the moment a rental token is issued for it — by
# `start_rental` for a licence-free scooter, by `rent_motorcycle` for the
# KYC-gated one — and never moves back, which is what makes a second
# activation of the same row a refusal rather than a second unlock token.
class Reservation < ApplicationRecord
  include Kiosk::Owned

  # The two states a reservation is ever written with. `reserved` is what
  # `reserve` creates and the ONLY state either rental verb will activate;
  # `active` is what activation writes.
  RESERVED = "reserved"
  ACTIVE   = "active"

  # ── The PAYMENT lifecycle, orthogonal to `status` above ────────────────────
  # `status` is the RIDE; this is the money. A reservation is `unpaid` until a
  # /pay CLAIMS it (`paying`, an atomic compare-and-set taken BEFORE the cashier
  # check and the capture), and `paid` the instant the capture returns — a hair
  # before the engine writes its settlement row. That ordering is the whole
  # point: protocol.md §11.6 anchors published paid state to the CAPTURE, never
  # to the settlement record.
  UNPAID = "unpaid"
  PAYING = "paying"
  PAID   = "paid"

  # What `my_reservations` publishes, and the three answers §11.6 allows.
  # `PENDING` is the third state the spec REQUIRES: a capture has been started
  # and its outcome is not known, which is neither paid nor not-paid, and which
  # an assistant must never read as a licence to sign a fresh mandate chain.
  STATE_UNPAID  = "unpaid"
  STATE_PENDING = "pending"
  STATE_PAID    = "paid"

  belongs_to :user
  belongs_to :scooter

  # The rows a rental verb may still activate. Both verbs require it, so it is
  # written once: a reservation already `active` (a ride in progress) is not
  # startable again, and answering that with the SAME refusal as "not yours"
  # is deliberate — see RentalGates.
  scope :still_reserved, -> { where(status: RESERVED) }


  # ── THE settled-cart containment, correlated to the row being selected ─────
  #
  # Why there are TWO spellings of one predicate, and why this one is a frozen
  # SQL literal where `Kiosk::CartMandate.referencing` is Arel. That scope binds a
  # SINGLE, CALLER-SUPPLIED reservation id, so the value must be quoted by the
  # adapter. This one binds NO value at all: it correlates the cart's line_items
  # against `reservations.id` — the column of whichever row the enclosing SELECT
  # is looking at — which is what lets `my_reservations` answer "paid?" for a
  # whole LIST in one statement instead of one query per row. Nothing here is
  # caller-controlled, the same exemption `own` rests on.
  SETTLED_CART_REFERENCES_THIS_ROW = Arel.sql(
    "kiosk.cart_mandates.line_items @> " \
    "json_build_array(json_build_object('reservation_id', reservations.id::text))::jsonb",
  ).freeze

  # The settlements — OF THE RELATION THE CALLER IS ENTITLED TO SEE — whose cart
  # references the reservation row being selected. `my_reservations` passes
  # `Kiosk::Settlement.own`; the parameter is what keeps the
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

  # ── The one place "has money moved for this rental" is decided ─────────────
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
  #   unpaid  — no capture has ever been claimed for this reservation. This is
  #             the ONLY positive, unambiguous "not paid" skooti ever publishes,
  #             and the only one that makes a fresh mandate chain correct.
  #
  # @param payment_status [String] the row's capture-anchored marker
  # @param settled [Boolean] whether a settlement the caller may see references it
  def self.payment_state(payment_status, settled)
    return STATE_PAID    if payment_status == PAID || settled
    return STATE_PENDING if payment_status == PAYING

    STATE_UNPAID
  end

  # ── WHAT THE EVENT SURFACE READS ───────────────────────────────────────────
  # The isolation predicate here resolves the principal from a Postgres GUC set
  # per request. A standing subscription is re-authorised on a timer, with no
  # request and no GUC, so this twin takes the account as an argument.
  #
  # @return [Boolean]
  def self.readable_by?(reservation_id, user_id)
    return false if reservation_id.to_s.empty? || user_id.to_s.empty?

    where(id: reservation_id, user_id: user_id).exists?
  end

  # The capture returned. The owner hears about it: the payer may be somebody else.
  def self.paid!(reservation_id)
    owner_id = where(id: reservation_id).pick(:user_id)
    return unless owner_id

    Kiosk::Server::Events.emit(
      topic: :booking_payment, subject: reservation_id, identity_scope: [owner_id],
      data: { "reservation_id" => reservation_id, "payment_state" => "paid" },
    )
  end
end
