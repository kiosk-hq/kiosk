# frozen_string_literal: true

# The cashier check, as a PSP-adapter decorator: before any capture, verify the
# agent-signed cart against the OPERATOR'S OWN quote. The wire checks the
# mandate chain's internal consistency; it cannot know this hotel's currency or
# the price it quoted. The operator must count what lands on the counter:
#
#   1. the cart is denominated in the operator's currency (EUR);
#   2. it references exactly one booking ({"booking_id": ...} among the
#      line_items — see reserve_room's pay_hint);
#   3. its total equals the price QUOTED for that booking (bookings.total_cents)
#      AND — when the cart carries priced lines — the sum of those lines.
#
# MONETARY ONLY: it deliberately does not check that the booking belongs to the
# payer — ownership is confirm_booking's Gate 1, and the isolation flow proves B
# may pay for A's booking at the right price and still be denied the confirm.
# Any mismatch rejects the capture (403); the mandate trail is persisted,
# nothing is charged.
#
# ── Per-booking serialization and the capture-anchored marker ────────────────
# The engine settles with the irreversible PSP capture BETWEEN two short DB
# transactions (executor P1→P2→P3), so the settlement row written in P3 cannot
# be the only "paid" marker: two /pay on two distinct chains would both charge,
# and during the window between capture and P3 every read would say "no
# settlement" about money that has already moved — the answer protocol.md §11.6
# forbids, because it licenses an assistant to charge its human twice.
#
# So the booking carries a lifecycle this decorator drives: `unpaid → paying →
# paid`. The claim is one conditional UPDATE (`… WHERE payment_status='unpaid'
# RETURNING …`), a row-locked race-free compare-and-set, so a second /pay matches
# zero rows and is refused and `my_bookings` publishes `pending`. WHO PAID is
# recorded with the claim, from the SIGNED cart mandate: without the payer id,
# confirm_booking's Gate 2 could not tell whose money it was and would have to
# widen from "a settlement of THIS principal" to "anyone paid".
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
      # Release ONLY when we know no money moved. On an UNKNOWN outcome the
      # booking stays `paying`, so a blind retry reads *pending* and is refused.
      release_claim_on_failure!(booking_id, e)
      raise
    end
    # Charge succeeded — mark terminally paid. This local flip is the FIRST
    # witness and the only one during the window; P3's settlement is the second.
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
  # engine's own marker, written in executor phase 3. It lands AFTER the
  # capture, so a false here proves nothing on its own.
  def self.settled?(booking_id)
    Settlement.joins(:cart_mandate).merge(CartMandate.referencing(booking_id)).exists?
  end

  private

  # Atomically claim the referenced booking for payment, then run the cashier
  # check against it. Returns the booking_id (String); raises Forbidden (403) on
  # a cashier rejection — reverting the claim first if it was taken — or
  # BadRequest (400) when the cart's booking reference is not even a uuid.
  def claim_and_validate!(cart)
    unless cart.currency.to_s.downcase == @currency
      deny "cart currency #{cart.currency.inspect} rejected — this operator prices in " \
           "#{@currency.upcase} (availability rows and reserve_room carry a currency field)"
    end

    entries = Array(cart.line_items)
    refs    = entries.filter_map { |li| li["booking_id"] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one booking_id (see reserve_room's pay_hint)" unless refs.size == 1
    booking_id = refs.first

    # The booking_id goes straight into an `::uuid` cast below, where a
    # malformed one raises InvalidTextRepresentation and escapes as a 500 — the
    # worst answer on the pay path, since an assistant cannot tell "your input
    # was wrong" from "the charge may have gone through". A 400 and not the
    # cashier's 403: this says nothing about whether any booking exists.
    unless UuidCheck.valid?(booking_id)
      raise Kiosk::Server::Errors::BadRequest.new(
        "cart line_items booking_id #{booking_id.inspect} is not a uuid",
        hint: "use the `booking_id` reserve_room returned, verbatim (a canonical uuid, " \
              "e.g. 3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b) — see its pay_hint",
      )
    end

    # CLAIM: unpaid → paying, race-free compare-and-set. Winning this
    # UPDATE is what serializes concurrent /pay for one booking, and it is taken
    # BEFORE the cashier check and before the capture, so a second chain never
    # reaches the PSP at all. RAW SQL because the ATOMICITY is the fix and
    # `update_all` has no RETURNING in Rails 8.1 — an ActiveRecord spelling would
    # be a SELECT then an UPDATE, i.e. the race back again. RAW BUT NOT
    # INTERPOLATED: every value is a `$N` bind, so the statement text carries no
    # value at all and there is no `conn.quote` to forget when this file is copied.
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
      # assistant gets an actionable sentence. NO owner filter, here or in the
      # claim: this cashier is monetary only; ownership is Gate 1's.
      existing = Booking.where(id: booking_id).pick(:payment_status)
      deny "booking not found" if existing.nil?

      # A `paying` booking that ALREADY HAS a settlement was charged and only
      # the local flip was lost (a crash between capture and mark_paid!). Heal
      # the marker here, where it matters, and answer with the truth.
      if existing == Booking::PAYING && self.class.settled?(booking_id)
        mark_paid!(booking_id)
        deny "booking already paid"
      end

      if existing == Booking::PAYING
        # Claimed, no settlement: a pay is in flight, or one died at an UNKNOWN
        # outcome and the claim was deliberately kept. Say what recovers it, in
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
      # Internal arithmetic consistency: if any line carries a per-unit price, the
      # total must equal the sum of qty × price_cents over those lines. A cart
      # with no priced lines skips this and rests on the quoted-total check.
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
  # required). On an UNKNOWN outcome (a non-retryable PaymentFailed) or any
  # unexpected error we deliberately do NOT release: leaving it `paying` is what
  # keeps `my_bookings` answering *pending* and blocks a blind retry.
  def release_claim_on_failure!(booking_id, error)
    return unless booking_id

    safe = error.is_a?(Kiosk::PaymentProviders::SetupRequired) ||
           (error.is_a?(Kiosk::PaymentProviders::PaymentFailed) && error.retryable?)
    release_claim!(booking_id) if safe
  end

  # Reverting also clears the payer: leaving a payer id would make
  # confirm_booking's Gate 2 read a released claim as a charge.
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

  # TWO WHOLE STATEMENTS, NOT ONE STATEMENT PLUS A FRAGMENT: both are
  # literal text with `$N` binds for every value, and the one difference between
  # them is a boolean at the call site rather than a SET fragment a caller could
  # grow.
  #
  # @param clear_payer [Boolean] true when reverting a claim — leaving a payer
  #   id would make confirm_booking's Gate 2 read it as a charge.
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
