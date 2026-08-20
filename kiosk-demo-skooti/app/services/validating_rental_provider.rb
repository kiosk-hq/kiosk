# frozen_string_literal: true

# The cashier check, as a PSP-adapter decorator: before any capture, verify
# the agent-signed cart against the OPERATOR'S OWN quote. The wire verifies the
# mandate chain's internal consistency (cart total == payment amount, one
# currency across the chain) — it cannot know this operator's currency or the
# price it quoted for a reservation. The operator must count what lands on the
# counter:
#
#   1. the cart is denominated in the operator's currency (EUR);
#   2. it references exactly one reservation ({"reservation_id": ...} among the
#      line_items — see reserve's pay_hint);
#   3. its total equals the price the operator QUOTED for that reservation AND
#      — when the cart carries priced line items — the sum of those lines
#      (internal arithmetic consistency).
#
# Skooti rentals are metered per-minute: there is no fixed total_cents stored on
# the reservation. The quote is derived — the reservation's scooter carries
# price_per_min_cents, and the pay step settles ONE minute upfront
# (price_per_min_cents × 1), mirroring reserve/rental_flow. So the quoted total
# for a reservation is that scooter's price_per_min_cents, read by joining the
# reservation to its scooter by id (NO user filter — ownership is not checked
# here).
#
# This is a MONETARY check only. It deliberately does NOT verify that the
# reservation belongs to the payer: skooti enforces settlement→reservation
# ownership at USE time (start_rental / rent_motorcycle Gate-1), and its
# isolation flow proves that B may pay for A's reservation at the correct price
# and currency — the settlement is valid, yet Gate-1 still denies B's
# start_rental. Ownership is not a payment concern here; the counter only
# checks the money. The KYC gate likewise lives at USE time and is untouched.
#
# Any mismatch rejects the capture (403 Forbidden); the mandate trail is
# persisted, nothing is charged.
#
# ── Per-reservation serialization and the capture-anchored marker (K-853) ────
# The engine settles between two short DB transactions with the irreversible PSP
# capture BETWEEN them (executor P1→P2→P3), and until K-853 the only "paid"
# marker skooti had was the settlement row written in P3, AFTER the capture.
# That left two holes, and protocol.md §11.6 now closes both by name:
#
#   (a) DOUBLE CAPTURE — two /pay for the same reservation (two distinct chains)
#       both passed the cashier and both charged the rider for one ride. The
#       engine's `409 conflict` on a re-presented mandate id does not help: a
#       FRESH chain collides with nothing.
#   (b) "NOT PAID" DURING THE WINDOW — between the capture returning and P3
#       writing the settlement, every skooti read said no settlement exists,
#       which §11.6 forbids an operator to publish as *not paid*: it is the
#       answer that licenses an assistant to sign a fresh chain and charge its
#       human a second time.
#
# So the reservation gets a payment lifecycle and this decorator drives it:
# `unpaid → paying → paid`. The claim is a single conditional UPDATE
# (`… WHERE payment_status='unpaid' RETURNING …`) — a row-locked, race-free
# compare-and-set. Once a reservation is `paying`, a second /pay's claim matches
# zero rows and is refused (closes a); `my_reservations` publishes `pending` for
# it rather than a bare unpaid (closes b, the in-flight half).
#
# On a definitive decline / no-charge failure we RELEASE `paying → unpaid` so a
# corrected retry can proceed; on an UNKNOWN outcome (a timeout) we deliberately
# LEAVE it `paying`, so a blind retry cannot double-charge and the state an
# assistant reads stays *pending* rather than becoming a false "not paid".
# On success we flip `paying → paid` BEFORE returning to the engine — a hair
# before P3 — and a failure of that flip must never undo a successful charge, so
# it is swallowed and P3's settlement row remains the second witness.
#
# WHO PAID is recorded with the claim, from the SIGNED cart mandate. skooti's
# cashier does not check that the payer owns the reservation (see above), so
# without the payer id the capture-anchored marker could not tell the rental
# verbs' payment gate whose money it was, and that gate would have had to widen
# from "a settlement of THIS principal" to "anyone paid" — which the isolation
# flow exists to prevent.
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
      # Release the claim ONLY when we know no money moved (a definitive decline
      # or a pre-charge SetupRequired). On an UNKNOWN outcome we keep the
      # reservation `paying` so a lost-response retry reads *pending* and is
      # refused, rather than reading *unpaid* and charging twice.
      release_claim_on_failure!(reservation_id, e)
      raise
    end
    # Charge succeeded — mark the reservation terminally paid. The engine's
    # settlement row (executor P3) is the second witness; this local flip is the
    # FIRST one and the only one that exists during the window, so a failure
    # here must NOT undo a successful charge — swallow it and let P3 record the
    # settlement.
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
    refs    = entries.filter_map { |li| li["reservation_id"] || li[:reservation_id] }.map(&:to_s).uniq
    deny "cart line_items must reference exactly one reservation_id (see reserve's pay_hint)" unless refs.size == 1
    reservation_id = refs.first

    # K-581: the reservation_id goes straight into an `::uuid` cast below. A
    # malformed one made Postgres raise InvalidTextRepresentation, which escaped
    # as a raw 500 — and on the pay path a 500 is the worst answer there is,
    # because an assistant cannot tell "your input was wrong" from "the charge
    # may have gone through". Reject the bad SHAPE up front, before the
    # connection is even taken — a 400, not the cashier's 403: this is a
    # malformed argument, not a refusal to serve a well-formed one, and it says
    # nothing about whether any reservation exists. The message echoes only the
    # value the agent itself sent — no SQL, no PG error text.
    unless UuidCheck.valid?(reservation_id)
      raise Kiosk::Server::Errors::BadRequest.new(
        "cart line_items reservation_id #{reservation_id.inspect} is not a uuid",
        hint: "use the `reservation_id` reserve returned, verbatim (a canonical uuid, " \
              "e.g. 3f0c1a2e-4b5d-6e7f-8a9b-0c1d2e3f4a5b) — see its pay_hint",
      )
    end

    conn = ActiveRecord::Base.connection

    # CLAIM: unpaid → paying, race-free compare-and-set (K-853). Winning this
    # UPDATE is what serializes concurrent /pay for one reservation — only one
    # caller can flip 'unpaid' — and it is taken BEFORE the cashier check and
    # before the capture, so a second chain never reaches the PSP at all. The
    # quoted total comes back with it: this reservation's scooter
    # price_per_min_cents × 1 minute (the upfront hold reserve/rental_flow
    # settle). No user_id filter — ownership is a USE-time gate, not the
    # cashier's.
    #
    # RAW SQL, deliberately: the ATOMICITY is the fix, `update_all` has no
    # RETURNING in Rails 8.1, and an ActiveRecord spelling would be a SELECT then
    # an UPDATE — which is the race back again. Nothing interpolated is
    # caller-controlled: the reservation id is through {UuidCheck}, the payer
    # comes off the SIGNED mandate, and the statuses are literals.
    claimed = conn.execute(
      "UPDATE public.reservations r " \
      "SET payment_status = #{conn.quote(Reservation::PAYING)}, " \
      "paid_by_user_id = #{conn.quote(cart.user_id.to_s)}::uuid, updated_at = now() " \
      "FROM public.scooters s " \
      "WHERE r.id = #{conn.quote(reservation_id)}::uuid " \
      "AND s.id = r.scooter_id " \
      "AND r.payment_status = #{conn.quote(Reservation::UNPAID)} " \
      "RETURNING s.price_per_min_cents"
    ).first

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
      priced = entries.select { |li| li["price_cents"] || li[:price_cents] }
      unless priced.empty?
        line_sum = priced.sum do |li|
          qty   = (li["qty"] || li[:qty]).to_i
          price = (li["price_cents"] || li[:price_cents]).to_i
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

  # Release a claim we know involved NO charge (a definitive decline / setup
  # required). On an UNKNOWN capture outcome (a non-retryable PaymentFailed) or
  # any other unexpected error we deliberately do NOT release — leaving the
  # reservation `paying` is what keeps `my_reservations` answering *pending*
  # instead of a false "not paid", and what blocks a blind retry.
  def release_claim_on_failure!(reservation_id, error)
    return unless reservation_id

    safe = error.is_a?(Kiosk::PaymentProviders::SetupRequired) ||
           (error.is_a?(Kiosk::PaymentProviders::PaymentFailed) && error.retryable?)
    release_claim!(reservation_id) if safe
  end

  # Reverting the claim also clears the payer: nobody paid, so leaving a payer id
  # on the row would make the rental verbs' payment gate read a claim that was
  # released as if it were a charge.
  def release_claim!(reservation_id)
    set_payment_status(reservation_id, from: Reservation::PAYING, to: Reservation::UNPAID,
                                       extra: "paid_by_user_id = NULL")
  end

  def mark_paid!(reservation_id)
    set_payment_status(reservation_id, from: Reservation::PAYING, to: Reservation::PAID)
  rescue StandardError
    # A successful charge is already on its way to the engine's settlement (P3);
    # a failed local flip must never surface as an error over a paid rental.
    nil
  end

  # @param extra [String, nil] a further frozen SET fragment — never a caller value
  def set_payment_status(reservation_id, from:, to:, extra: nil)
    conn = ActiveRecord::Base.connection
    conn.execute(
      "UPDATE public.reservations SET payment_status = #{conn.quote(to)}, " \
      "#{extra ? "#{extra}, " : ""}updated_at = now() " \
      "WHERE id = #{conn.quote(reservation_id.to_s)}::uuid AND payment_status = #{conn.quote(from)}"
    )
  end

  def deny(message)
    raise Kiosk::Server::Errors::Forbidden.new(message)
  end
end
