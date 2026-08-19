# frozen_string_literal: true

# hoteling's WRITE surface: the three verbs an assistant reaches with
# `POST /kiosk/run`. Same shape as Kiosk::HotelsController — `ActionController::API`
# plus `include Kiosk::Action` — because a controller declares queries OR actions,
# never both.
#
# THE TWO WRITES ARE FOUR LINES EACH: read the arguments off the request, hand
# them to an Operation, render what it answers. That is deliberate. `reserve_room`
# is a transaction with a three-part inventory guard whose middle part is an
# INSERT that may raise, and `confirm_booking` is a transaction with two gates and
# a COALESCE'd UPDATE; a `render` in the middle of either is what the earlier
# slices had to reason about, and moving them to app/operations/ is what makes
# them callable from anywhere — a console, a rake task, or a second human-facing
# surface if hoteling ever grows one (it has none today; its web page is
# read-only counts).
#
# `payment_setup` deliberately stays HERE. It writes nothing: it asks the
# configured payment provider one question and renders the answer, which is the
# same reason tudu left its queries in the handler — a call plus a literal has
# nothing to extract.
#
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary `render json:,
# status:` naming the code, and the wire carries it verbatim. No Kiosk error
# classes appear below — an Operation answers with an {OperationResult}, and
# {KioskRefusals#render_operation} is the one place that becomes a status.
#
# Nothing here means a 402. The wire's three payment/PoW codes share that status
# and `Errors::STATUS_CODES` deliberately refuses to guess between them; the 402s
# an assistant meets on this origin come from the registration PoW gate (always
# on) and the browse-rate gate (KIOSK_POW_BROWSE_DEMO=1), both upstream of
# dispatch, never from a handler.
#
# NOT ROUTABLE — see Kiosk::HotelsController.
class Kiosk::ReservationsController < ActionController::API
  include Kiosk::Action
  include KioskRefusals

  # payment_setup — canonical skill Step 5 runs this unconditionally before
  # `pay`. Mirrors the getgrocery registration shape; with StubPsp
  # (no SetupIntent model) setup_required? is always false, so this is an
  # immediate no-op success: {status: "ready"}.
  #
  # POLL CADENCE + STOP CONDITION (K-477/K-595): the wire has no server→assistant
  # push, so an assistant that ever DOES get a `setup_required` learns the human
  # finished the hosted card entry ONLY by re-calling this. The descriptor
  # therefore has to state a cadence AND a terminal stop condition — without one an
  # agent invents its own and can poll forever if the human never completes the
  # step. Stated even though this demo's StubPsp short-circuits it, so the
  # PUBLISHED contract is the same across all three payment demos.
  #
  # The cadence here is the skill's, verbatim (skill.md Step 5: ~5 s for the first
  # minute, then ~15 s, give up after ~5 minutes) — the skill is what assistants
  # actually follow, so a descriptor that prescribes anything else is a second,
  # losing instruction. And no CHECK COUNT is stated: a count is derived from the
  # cadence and the horizon, so it silently goes wrong the moment either moves
  # (the earlier "~60 checks" implied a flat 5 s cadence and was more than double
  # what this schedule yields). The horizon is the number an assistant needs.
  #
  # NOTE getgrocery's descriptor also promises the setup_url is stable across polls
  # (K-492 — a real-Stripe SetupIntent-reuse property). That promise is NOT
  # repeated here: StubPsp mints no setup session at all, so there is nothing to be
  # stable about and claiming it would be a claim about code this demo never runs.
  description "Check whether the authenticated principal has a saved payment method. " \
              "Returns {status: \"ready\"} when the assistant can proceed to `pay`. " \
              "Returns {status: \"setup_required\", setup_url: \"…\"} when a hosted setup flow " \
              "must be completed by the human first — hand the setup_url to the human, wait for " \
              "them to finish, then call payment_setup again before paying. " \
              "This demo's stub PSP needs no setup, so it always returns ready. " \
              "The assistant should call this before `pay`. " \
              "POLLING: if you ever do get setup_required, re-check every ~5 seconds for the first " \
              "minute, then every ~15 seconds, while your human is at the hosted page, and GIVE UP " \
              "after about 5 minutes — tell your human the card setup is still not finished rather " \
              "than polling indefinitely; they can finish later and you re-check then."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # TWO shapes, and the branch is `status`. Declared as a `oneOf` rather than
  # one open object with an optional `setup_url`, because the pairing is the
  # contract: `setup_required` without a url is an answer the assistant cannot
  # act on. This demo's stub PSP only ever produces the first branch — the
  # second is declared anyway, so the PUBLISHED contract is the same across all
  # three payment demos and an operator swapping in a real PSP changes no
  # descriptor.
  output_schema oneOf: [
    { type: "object", additionalProperties: false,
      description: "A payment method is on file — proceed to `pay`.",
      properties: { status: { const: "ready", description: "ready." } },
      required: ["status"] },
    { type: "object", additionalProperties: false,
      description: "A hosted setup flow must be completed by the human first.",
      properties: {
        status:    { const: "setup_required", description: "setup_required." },
        setup_url: { type: "string", description: "The hosted setup page to hand to your human." },
      },
      required: %w[status setup_url] },
  ]
  def payment_setup
    # The principal, from the identity the WIRE resolved. This used to be a
    # `SELECT kiosk.current_user_id()` round trip followed by a nil check that
    # raised `Unauthenticated` — and that check was UNREACHABLE: the wire resolves
    # an identity before dispatch and answers 401 itself when it cannot, which is
    # exactly what the anonymous probe gets ("no identity resolved from request",
    # never this handler's "no authenticated user"). The round trip and the dead
    # branch go together.
    user_id  = kiosk_identity.user_id
    provider = Kiosk.configuration.payment_provider

    if provider.setup_required?(user_id: user_id)
      render json: { status: "setup_required", setup_url: provider.setup_url(user_id: user_id) }
    else
      render json: { status: "ready" }
    end
  end

  # reserve_room — the TTL hold. See {ReserveRoomOperation} for the inventory
  # guard; the two identity values below are the only things this controller
  # contributes, and both are read from the identity the wire resolved rather than
  # from arguments, which is what makes a forged `user_id` in the body inert.
  description "Reserve a room for the authenticated principal (creates a TTL hold). " \
              "To pay, sign your AP2 cart mandate in EUR at the quoted total_cents with a " \
              "line_item that references the returned booking_id; the operator verifies " \
              "currency and total against its quote before charging (the result carries a pay_hint)"
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 property_id:  { type: "integer",
                                 description: "The property to book — the `property_id` from a " \
                                              "properties or availability-bearing row." },
                 room_type_id: { type: "integer",
                                 description: "The room type to hold — the `room_type_id` from an " \
                                              "availability row for these same dates." },
                 check_in:     { type: "string", format: "date",
                                 description: "First night (YYYY-MM-DD)." },
                 check_out:    { type: "string", format: "date",
                                 description: "Checkout day (YYYY-MM-DD, exclusive) — a checkout day " \
                                              "is the next guest's check-in day, so it may equal " \
                                              "another booking's check_in." },
               },
               required: ["property_id", "room_type_id", "check_in", "check_out"]
  output_schema type: "object",
                description: "The TTL hold, and the quote the cart must be signed against.",
                additionalProperties: false,
                properties: {
                  booking_id:          { type: "string", description: "uuid. Name it in the cart mandate's line item, and pass it to confirm_booking as `booking_id`." },
                  total_cents:         { type: "integer", description: "EUR cents for the WHOLE stay — sign the cart at exactly this total." },
                  currency:            { type: "string", description: "eur — the currency the cart must be signed in." },
                  nights:              { type: "integer", description: "Nights the hold covers." },
                  nightly_price_cents: { type: "integer", description: "EUR cents per night; nights × this is total_cents." },
                  pay_hint:            { type: "string", description: "The mandate this hold expects, in words." },
                },
                required: %w[booking_id total_cents currency nights nightly_price_cents pay_hint]
  def reserve_room
    render_operation ReserveRoomOperation.call(
      principal_id: kiosk_identity.user_id,
      agent_id:     kiosk_identity.agent_id,
      property_id:  params[:property_id],
      room_type_id: params[:room_type_id],
      check_in:     params[:check_in],
      check_out:    params[:check_out],
    )
  end

  # confirm_booking — the two gates and the durable confirmation code. See
  # {ConfirmBookingOperation}; the principal is NOT passed in because both gates
  # express it as a WHERE predicate over `kiosk.current_user_id()`, which is
  # un-forgeable without naming it in Ruby at all.
  description "Confirm a reserved booking (requires payment mandate referencing this booking). " \
              "Returns the `confirmation_code` the hotel stores against the booking — the " \
              "reference the guest gives at the desk. It is durable: the same code is listed " \
              "by my_bookings afterwards, and confirming again never mints a different one."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 booking_id: { type: "string", format: "uuid",
                               description: "The booking to confirm — a `booking_id` from " \
                                            "reserve_room or my_bookings, verbatim; it must " \
                                            "belong to the principal and still be reserved." },
               },
               required: ["booking_id"]
  output_schema type: "object",
                description: "The confirmed booking and its durable desk reference.",
                additionalProperties: false,
                properties: {
                  booking_id:        { type: "string", description: "The booking that was confirmed, echoed." },
                  status:            { const: "confirmed", description: "confirmed." },
                  confirmation_code: { type: "string", description: "The reference the guest gives at the desk. Durable: my_bookings lists the same code afterwards, and confirming again never mints a different one." },
                },
                required: %w[booking_id status confirmation_code]
  def confirm_booking
    render_operation ConfirmBookingOperation.call(booking_id: params[:booking_id])
  end
end
