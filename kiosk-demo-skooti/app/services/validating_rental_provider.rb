# frozen_string_literal: true

# The cashier check, as a PSP-adapter decorator: before any capture, verify the
# agent-signed cart against the OPERATOR'S OWN quote. The wire checks the mandate
# chain's internal consistency (cart total == payment amount, one currency
# throughout); it cannot know this operator's currency or the price it quoted.
# So the operator counts what lands on the counter:
#
#   1. the cart is denominated in the operator's currency (EUR);
#   2. it references exactly one reservation ({"reservation_id": ...} among the
#      line_items — see reserve's pay_hint);
#   3. its total equals the price the operator QUOTED for that reservation AND,
#      when the cart carries priced line items, the sum of those lines.
#
# Rentals are metered per-minute, so no fixed total is stored: the quote is
# derived from the reservation's scooter (price_per_min_cents × the one minute
# the pay step settles upfront, mirroring reserve/rental_flow), read by joining
# the reservation to its scooter — no user filter, because ownership is not
# checked here.
#
# MONETARY ONLY. It deliberately does not verify that the reservation belongs to
# the payer: skooti enforces settlement→reservation ownership at USE time
# (start_rental / rent_motorcycle Gate 1), and the isolation flow proves B may
# pay for A's reservation at the right price and still be denied start_rental.
# The KYC gate likewise lives at use time.
#
# Any mismatch rejects the capture (403 Forbidden); the mandate trail is
# persisted, nothing is charged.
#
# ── Per-reservation serialization and the capture-anchored marker (K-853) ────
# The engine settles across two short DB transactions with the irreversible PSP
# capture BETWEEN them (executor P1→P2→P3), so a settlement row written in P3 is
# too late to close two holes protocol.md §11.6 names:
#
#   (a) DOUBLE CAPTURE — two /pay for one reservation over two distinct chains
#       both pass the cashier and both charge the rider. The engine's `409` on a
#       re-presented mandate id does not help: a FRESH chain collides with
#       nothing.
#   (b) "NOT PAID" DURING THE WINDOW — between the capture returning and P3
#       writing the settlement every read says no settlement exists, which §11.6
#       forbids publishing as *not paid*: that answer licenses an assistant to
#       sign a fresh chain and charge its human twice.
#
# So the reservation carries a payment lifecycle, `unpaid → paying → paid`, and
# this decorator drives it. The claim is a single conditional UPDATE
# (`… WHERE payment_status='unpaid' RETURNING …`) — a row-locked, race-free
# compare-and-set. Once a reservation is `paying`, a second /pay's claim matches
# zero rows and is refused (a), and `my_reservations` publishes `pending` rather
# than a bare unpaid (b).
#
# On a definitive decline we RELEASE `paying → unpaid` so a corrected retry can
# proceed; on an UNKNOWN outcome (a timeout) we deliberately LEAVE it `paying`,
# so a blind retry cannot double-charge and the state an assistant reads stays
# *pending* rather than a false "not paid". On success we flip `paying → paid`
# just before returning to the engine, and a failure of that flip must never undo
# a successful charge, so it is swallowed and P3's settlement row is the second
# witness.
#
# WHO PAID is recorded with the claim, from the SIGNED cart mandate: the cashier
# does not check that the payer owns the reservation, so without the payer id the
# rental verbs' payment gate would have to widen from "a settlement of THIS
# principal" to "anyone paid" — which the isolation flow exists to prevent.
class ValidatingRentalProvider
  def initialize(provider, currency:)
    @provider = provider
    @currency = currency.to_s.downcase
  end

  def capture(cart_mandate, payment_method: nil)
    reservation_id = claim_and_validate!(cart_mandate)
    begin
      settled = @provider.capture(cart_mandate, payment_method: payment_method)
    rescue StandardError => e
      # Release the claim ONLY when we know no money moved.
      release_claim_on_failure!(reservation_id, e)
      raise
    end
    # The FIRST witness, and the only one that exists during the window before
    # the engine's settlement row (P3) lands.
    mark_paid!(reservation_id)
    settled
  end

  def method_missing(name, *args, **kwargs, &block)
    @provider.public_send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    @provider.respond_to?(name, include_private) || super
  end

  # True iff a settlement (capture receipt) references this reservation — the
  # engine's own "this was charged" marker, written by executor phase 3. It is
  # the SECOND witness: it lands after the capture, so a false here proves
  # nothing on its own, which is precisely why the claim above exists.
  def self.settled?(reservation_id)
    Settlement.joins(:cart_mandate).merge(CartMandate.referencing(reservation_id)).exists?
  end

  private

  # Atomically claim the referenced reservation for payment, then run the
  # cashier check against it. Returns the reservation_id (String) on success;
  # raises Forbidden (403) on a cashier rejection — reverting the claim first if
  # it was taken — or BadRequest (400) when the cart's reservation reference is
  # not even a uuid (checked before the claim, so there is nothing to revert).
  def claim_and_validate!(cart)
    unless cart.currency.to_s.downcase == @currency
      deny "cart currency #{cart.currency.inspect} rejected — this operator prices in " \
           "#{@currency.upcase} (the fleet catalog and reserve carry a currency field)"
    end

    entries = Array(cart.line_items)
    refs    = entries.filter_map { |li| li["reservation_id"] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one reservation_id (see reserve's pay_hint)" unless refs.size == 1
    reservation_id = refs.first

    # The reservation_id goes straight into an `::uuid` cast below, where a
    # malformed one raises InvalidTextRepresentation — and on the pay path a 500
    # is the worst answer there is, because an assistant cannot tell "your input
    # was wrong" from "the charge may have gone through" (K-581). So the SHAPE is
    # rejected before a connection is even taken, and as a 400 rather than the
    # cashier's 403: a malformed argument, not a refusal to serve a well-formed
    # one, and it says nothing about whether any reservation exists. The message
    # echoes only what the agent sent — no SQL, no PG error text.
    unless UuidCheck.valid?(reservation_id)
      raise Kiosk::Server::Errors::BadRequest.new(
        "cart line_items reservation_id #{reservation_id.inspect} is not a uuid",
        hint: "use the `reservation_id` reserve returned, verbatim (a canonical uuid, " \
              "e.g. 3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b) — see its pay_hint",
      )
    end

    # CLAIM: unpaid → paying, race-free compare-and-set (K-853). Winning this
    # UPDATE is what serializes concurrent /pay for one reservation — only one
    # caller can flip 'unpaid' — and it is taken BEFORE the cashier check and
    # before the capture, so a second chain never reaches the PSP at all. The
    # quoted total rides back with it. No user_id filter: ownership is a USE-time
    # gate, not the cashier's.
    #
    # Raw SQL, deliberately: the ATOMICITY is the point, `update_all` has no
    # RETURNING in Rails 8.1, and an ActiveRecord spelling would be a SELECT then
    # an UPDATE — the race back again. Raw but NOT interpolated (K-654): every
    # value is a `$N` bind, so the statement text carries no value at all and
    # there is no `conn.quote` to forget when this file is copied.
    claimed = Reservation.lease_connection.exec_query(
      "UPDATE public.reservations r " \
      "SET payment_status = $1, " \
      "paid_by_user_id = $2::uuid, updated_at = now() " \
      "FROM public.scooters s " \
      "WHERE r.id = $3::uuid " \
      "AND s.id = r.scooter_id " \
      "AND r.payment_status = $4 " \
      "RETURNING s.price_per_min_cents",
      "skooti reservation claim",
      [Reservation::PAYING, cart.user_id.to_s, reservation_id, Reservation::UNPAID]
    ).to_a.first

    if claimed.nil?
      # Distinguish "no such reservation" from "not in a payable state", so the
      # assistant gets an actionable sentence instead of a bare 403.
      existing = Reservation.where(id: reservation_id).pick(:payment_status)
      deny "reservation not found" if existing.nil?

      # A `paying` reservation that ALREADY HAS a settlement was charged and only
      # the local flip was lost (a crash between capture and mark_paid!). The
      # settlement row is decisive evidence, so heal the marker here — at the
      # moment it matters — and answer with the truth.
      if existing == Reservation::PAYING && self.class.settled?(reservation_id)
        mark_paid!(reservation_id)
        deny "reservation already paid"
      end

      if existing == Reservation::PAYING
        # Claimed, no settlement: either a pay is genuinely in flight, or one
        # died at an UNKNOWN outcome and we deliberately kept the claim so a
        # blind retry cannot double-charge. Say what recovers it, in the
        # vocabulary §11.6 gave the assistant.
        deny "reservation #{reservation_id} has a payment in progress — re-read " \
             "GET <endpoint>/my_reservations: while its payment_state is `pending` the charge may " \
             "already have gone through, so do NOT sign a fresh mandate chain; only a `paid` or " \
             "`unpaid` answer is actionable"
      end

      deny "reservation #{reservation_id} is already paid — start_rental / rent_motorcycle is the " \
           "next step, not a second payment"
    end

    quoted = claimed["price_per_min_cents"].to_i

    # Everything past the claim runs under the `paying` guard; any rejection
    # must release it (revert to 'unpaid') so a corrected retry can proceed.
    begin
      # Internal arithmetic consistency: if any line carries a per-unit price,
      # the cart's total must equal the sum of qty × price_cents across those
      # lines. Carts with no priced lines (e.g. the isolation-flow cart) skip
      # this sub-check and are guarded by the quoted-total check alone.
      priced = entries.select { |li| li["price_cents"] }
      unless priced.empty?
        line_sum = priced.sum do |li|
          qty   = li["qty"].to_i
          price = li["price_cents"].to_i
          deny "each priced line needs a positive qty and price_cents" if qty <= 0 || price <= 0
          qty * price
        end
        unless cart.total_amount_cents.to_i == line_sum
          deny "cart total #{cart.total_amount_cents} does not equal the sum of its line items #{line_sum}"
        end
      end

      unless cart.total_amount_cents.to_i == quoted
        deny "cart total #{cart.total_amount_cents} does not equal the operator's quoted rental price " \
             "#{quoted} — re-read the fleet catalog and reserve's pay_hint"
      end
    rescue StandardError
      release_claim!(reservation_id) # revert 'paying' → 'unpaid'
      raise
    end

    reservation_id
  end

  # A definitive decline or a pre-charge SetupRequired is the only case where no
  # money moved. On an UNKNOWN outcome (a non-retryable PaymentFailed, any other
  # error) we deliberately do NOT release: leaving the reservation `paying` is
  # what keeps `my_reservations` answering *pending* instead of a false "not
  # paid", and what blocks a blind retry.
  def release_claim_on_failure!(reservation_id, error)
    return unless reservation_id

    safe = error.is_a?(Kiosk::PaymentProviders::SetupRequired) ||
           (error.is_a?(Kiosk::PaymentProviders::PaymentFailed) && error.retryable?)
    release_claim!(reservation_id) if safe
  end

  # Clears the payer too: nobody paid, and a payer id left on the row would make
  # the rental verbs' payment gate read a released claim as a charge.
  def release_claim!(reservation_id)
    set_payment_status(reservation_id, from: Reservation::PAYING, to: Reservation::UNPAID,
                                       clear_payer: true)
  end

  def mark_paid!(reservation_id)
    set_payment_status(reservation_id, from: Reservation::PAYING, to: Reservation::PAID)
  rescue StandardError
    # A successful charge is already on its way to the engine's settlement (P3);
    # a failed local flip must never surface as an error over a paid rental.
    nil
  end

  # Two WHOLE statements rather than one plus a spliced SET fragment (K-654):
  # every reader sees a complete statement, both are literal text with `$N` binds
  # for every value, and the one difference between them — whether the payer is
  # cleared — is a boolean at the call site rather than a string a caller could
  # grow.
  #
  # @param clear_payer [Boolean] true when reverting a claim.
  def set_payment_status(reservation_id, from:, to:, clear_payer: false)
    sql =
      if clear_payer
        "UPDATE public.reservations SET payment_status = $1, paid_by_user_id = NULL, " \
        "updated_at = now() WHERE id = $2::uuid AND payment_status = $3"
      else
        "UPDATE public.reservations SET payment_status = $1, updated_at = now() " \
        "WHERE id = $2::uuid AND payment_status = $3"
      end

    Reservation.lease_connection.exec_update(sql, "skooti reservation status flip",
                                             [to, reservation_id.to_s, from])
  end

  def deny(message)
    raise Kiosk::Server::Errors::Forbidden.new(message)
  end
end
