# frozen_string_literal: true

# The cashier check, as a PSP-adapter decorator: before any capture, verify
# the agent-signed cart against the OPERATOR'S OWN quote. The wire verifies the
# mandate chain's internal consistency (cart total == payment amount, one
# currency across the chain) — it cannot know this hotel's currency or the
# price it quoted for a booking. The operator must count what lands on the
# counter:
#
#   1. the cart is denominated in the operator's currency (EUR);
#   2. it references exactly one booking ({"booking_id": ...} among the
#      line_items — see reserve_room's pay_hint);
#   3. its total equals the price the operator QUOTED for that booking
#      (bookings.total_cents, read by id) AND — when the cart carries priced
#      line items — the sum of those lines (internal arithmetic consistency).
#
# This is a MONETARY check only. It deliberately does NOT verify that the
# booking belongs to the payer: hoteling enforces settlement→booking ownership
# at USE time (confirm_booking Gate-1), and its isolation flow proves that B
# may pay for A's booking at the correct price and currency — the settlement is
# valid, yet Gate-1 still denies B's confirm_booking. Ownership is not a
# payment concern here; the counter only checks the money.
#
# Any mismatch rejects the capture (403 Forbidden); the mandate trail is
# persisted, nothing is charged.
#
# ── Per-booking serialization and the capture-anchored marker (K-853) ────────
# The engine settles between two short DB transactions with the irreversible PSP
# capture BETWEEN them (executor P1→P2→P3), and until K-853 the only "paid"
# marker hoteling had was the settlement row written in P3, AFTER the capture.
# That left two holes, and protocol.md §11.6 now closes both by name:
#
#   (a) DOUBLE CAPTURE — two /pay for the same booking (two distinct chains)
#       both passed the cashier and both charged. The engine's `409 conflict` on
#       a re-presented mandate id does not help: a FRESH chain collides with
#       nothing.
#   (b) "NOT PAID" DURING THE WINDOW — between the capture returning and P3
#       writing the settlement, every hoteling read said no settlement exists,
#       which §11.6 forbids an operator to publish as *not paid*: it is the
#       answer that licenses an assistant to sign a fresh chain and charge its
#       human a second time.
#
# So the booking gets a payment lifecycle and this decorator drives it:
# `unpaid → paying → paid`. The claim is a single conditional UPDATE
# (`… WHERE payment_status='unpaid' RETURNING …`) — a row-locked, race-free
# compare-and-set. Once a booking is `paying`, a second /pay's claim matches
# zero rows and is refused (closes a); `my_bookings` publishes `pending` for it
# rather than a bare unpaid (closes b, the in-flight half).
#
# On a definitive decline / no-charge failure we RELEASE `paying → unpaid` so a
# corrected retry can proceed; on an UNKNOWN outcome (a timeout) we deliberately
# LEAVE it `paying`, so a blind retry cannot double-charge and the state an
# assistant reads stays *pending* rather than becoming a false "not paid".
# On success we flip `paying → paid` BEFORE returning to the engine — a hair
# before P3 — and a failure of that flip must never undo a successful charge, so
# it is swallowed and P3's settlement row remains the second witness.
#
# WHO PAID is recorded with the claim, from the SIGNED cart mandate. hoteling's
# cashier does not check that the payer owns the booking (see above), so without
# the payer id the capture-anchored marker could not tell `confirm_booking`'s
# Gate 2 whose money it was, and Gate 2 would have had to widen from "a
# settlement of THIS principal" to "anyone paid" — which the isolation flow
# exists to prevent.
class ValidatingBookingProvider
  def initialize(provider, currency:)
    @provider = provider
    @currency = currency.to_s.downcase
  end

  def capture(cart_mandate, payment_method: nil)
    booking_id = claim_and_validate!(cart_mandate)
    begin
      settled = @provider.capture(cart_mandate, payment_method: payment_method)
    rescue StandardError => e
      # Release the claim ONLY when we know no money moved (a definitive decline
      # or a pre-charge SetupRequired). On an UNKNOWN outcome we keep the booking
      # `paying` so a lost-response retry reads *pending* and is refused, rather
      # than reading *unpaid* and charging twice.
      release_claim_on_failure!(booking_id, e)
      raise
    end
    # Charge succeeded — mark the booking terminally paid. The engine's
    # settlement row (executor P3) is the second witness; this local flip is the
    # FIRST one and the only one that exists during the window, so a failure
    # here must NOT undo a successful charge — swallow it and let P3 record the
    # settlement.
    mark_paid!(booking_id)
    settled
  end

  def method_missing(name, *args, **kwargs, &block)
    @provider.public_send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    @provider.respond_to?(name, include_private) || super
  end

  # True iff a settlement (capture receipt) references this booking — the
  # engine's own "this was charged" marker, written by executor phase 3. It is
  # the SECOND witness: it lands after the capture, so a false here proves
  # nothing on its own, which is precisely why the claim above exists.
  def self.settled?(booking_id)
    Settlement.joins(:cart_mandate).merge(CartMandate.referencing(booking_id)).exists?
  end

  private

  # Atomically claim the referenced booking for payment, then run the cashier
  # check against it. Returns the booking_id (String) on success; raises
  # Forbidden (403) on a cashier rejection — reverting the claim first if it was
  # taken — or BadRequest (400) when the cart's booking reference is not even a
  # uuid (checked before the claim, so there is nothing to revert).
  def claim_and_validate!(cart)
    unless cart.currency.to_s.downcase == @currency
      deny "cart currency #{cart.currency.inspect} rejected — this operator prices in " \
           "#{@currency.upcase} (availability rows and reserve_room carry a currency field)"
    end

    entries = Array(cart.line_items)
    refs    = entries.filter_map { |li| li["booking_id"] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one booking_id (see reserve_room's pay_hint)" unless refs.size == 1
    booking_id = refs.first

    # K-581: the booking_id goes straight into an `::uuid` cast below. A
    # malformed one made Postgres raise InvalidTextRepresentation, which escaped
    # as a raw 500 — and on the pay path a 500 is the worst answer there is,
    # because an assistant cannot tell "your input was wrong" from "the charge
    # may have gone through". Reject the bad SHAPE up front, before the
    # connection is even taken — a 400, not the cashier's 403: this is a
    # malformed argument, not a refusal to serve a well-formed one, and it says
    # nothing about whether any booking exists. The message echoes only the
    # value the agent itself sent — no SQL, no PG error text.
    unless UuidCheck.valid?(booking_id)
      raise Kiosk::Server::Errors::BadRequest.new(
        "cart line_items booking_id #{booking_id.inspect} is not a uuid",
        hint: "use the `booking_id` reserve_room returned, verbatim (a canonical uuid, " \
              "e.g. 3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b) — see its pay_hint",
      )
    end

    # CLAIM: unpaid → paying, race-free compare-and-set (K-853). Winning this
    # UPDATE is what serializes concurrent /pay for one booking — only one
    # caller can flip 'unpaid' — and it is taken BEFORE the cashier check and
    # before the capture, so a second chain never reaches the PSP at all.
    #
    # RAW SQL, deliberately, and for the reason getgrocery's twin gives: the
    # ATOMICITY is the fix, `update_all` has no RETURNING in Rails 8.1, and an
    # ActiveRecord spelling would be a SELECT then an UPDATE — which is the race
    # back again. RAW, BUT NOT INTERPOLATED (K-654): every value is a `$N` bind,
    # so the statement text carries no value at all and there is no
    # `conn.quote` to forget when this file is copied. `$2::uuid` casts the
    # bound text exactly as the quoted literal did.
    claimed = Booking.lease_connection.exec_query(
      "UPDATE public.bookings SET payment_status = $1, " \
      "paid_by_user_id = $2::uuid, updated_at = now() " \
      "WHERE id = $3::uuid " \
      "AND payment_status = $4 " \
      "RETURNING total_cents",
      "hoteling booking claim",
      [Booking::PAYING, cart.user_id.to_s, booking_id, Booking::UNPAID]
    ).to_a.first

    if claimed.nil?
      # Distinguish "no such booking" from "not in a payable state", so the
      # assistant gets an actionable sentence instead of a bare 403. NO owner
      # filter, here or in the claim: this cashier is monetary only (see the
      # header) and ownership is confirm_booking's Gate 1.
      existing = Booking.where(id: booking_id).pick(:payment_status)
      deny "booking not found" if existing.nil?

      # A `paying` booking that ALREADY HAS a settlement was charged and only
      # the local flip was lost (a crash between capture and mark_paid!). The
      # settlement row is decisive evidence, so heal the marker here — at the
      # moment it matters — and answer with the truth.
      if existing == Booking::PAYING && self.class.settled?(booking_id)
        mark_paid!(booking_id)
        deny "booking already paid"
      end

      if existing == Booking::PAYING
        # Claimed, no settlement: either a pay is genuinely in flight, or one
        # died at an UNKNOWN outcome and we deliberately kept the claim so a
        # blind retry cannot double-charge. Say what recovers it, and say it in
        # the vocabulary §11.6 gave the assistant.
        deny "booking #{booking_id} has a payment in progress — re-read GET <endpoint>/my_bookings: " \
             "while its payment_state is `pending` the charge may already have gone through, so do NOT " \
             "sign a fresh mandate chain; only a `paid` or `unpaid` answer is actionable"
      end

      deny "booking #{booking_id} is already paid — confirm_booking is the next step, not a second payment"
    end

    quoted = claimed["total_cents"].to_i

    # Everything past the claim runs under the `paying` guard; any rejection
    # must release it (revert to 'unpaid') so a corrected retry can proceed.
    begin
      # Internal arithmetic consistency: if any line carries a per-unit price,
      # the cart's total must equal the sum of qty × price_cents across those
      # lines. Carts that carry no priced lines (e.g. the isolation-flow cart)
      # skip this sub-check and are guarded by the quoted-total check alone.
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
        deny "cart total #{cart.total_amount_cents} does not equal the price quoted for this booking " \
             "#{quoted} — re-read availability and reserve_room's pay_hint"
      end
    rescue StandardError
      release_claim!(booking_id) # revert 'paying' → 'unpaid'
      raise
    end

    booking_id
  end

  # Release a claim we know involved NO charge (a definitive decline / setup
  # required). On an UNKNOWN capture outcome (a non-retryable PaymentFailed) or
  # any other unexpected error we deliberately do NOT release — leaving the
  # booking `paying` is what keeps `my_bookings` answering *pending* instead of
  # a false "not paid", and what blocks a blind retry.
  def release_claim_on_failure!(booking_id, error)
    return unless booking_id

    safe = error.is_a?(Kiosk::PaymentProviders::SetupRequired) ||
           (error.is_a?(Kiosk::PaymentProviders::PaymentFailed) && error.retryable?)
    release_claim!(booking_id) if safe
  end

  # Reverting the claim also clears the payer: nobody paid, so leaving a payer id
  # on the row would make `confirm_booking`'s Gate 2 read a claim that was
  # released as if it were a charge.
  def release_claim!(booking_id)
    set_payment_status(booking_id, from: Booking::PAYING, to: Booking::UNPAID, clear_payer: true)
  end

  def mark_paid!(booking_id)
    set_payment_status(booking_id, from: Booking::PAYING, to: Booking::PAID)
  rescue StandardError
    # A successful charge is already on its way to the engine's settlement (P3);
    # a failed local flip must never surface as an error over a paid booking.
    nil
  end

  # TWO WHOLE STATEMENTS, NOT ONE STATEMENT PLUS A FRAGMENT (K-654). This used
  # to take an `extra:` SET fragment and splice it in, which meant no reader
  # ever saw a complete statement and the file taught fragment-splicing as a
  # technique. Written out, both are literal text with `$N` binds for every
  # value, and the ONE difference between them — whether the payer is cleared —
  # is a boolean at the call site rather than a string a caller could grow.
  #
  # @param clear_payer [Boolean] true when reverting a claim: nobody paid, so
  #   leaving a payer id would make confirm_booking's Gate 2 read a released
  #   claim as a charge.
  def set_payment_status(booking_id, from:, to:, clear_payer: false)
    sql =
      if clear_payer
        "UPDATE public.bookings SET payment_status = $1, paid_by_user_id = NULL, updated_at = now() " \
        "WHERE id = $2::uuid AND payment_status = $3"
      else
        "UPDATE public.bookings SET payment_status = $1, updated_at = now() " \
        "WHERE id = $2::uuid AND payment_status = $3"
      end

    Booking.lease_connection.exec_update(sql, "hoteling booking status flip",
                                         [to, booking_id.to_s, from])
  end

  def deny(message)
    raise Kiosk::Server::Errors::Forbidden.new(message)
  end
end
