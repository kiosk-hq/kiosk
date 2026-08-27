# frozen_string_literal: true

# hoteling's WRITE surface: the three verbs an assistant reaches with
# `POST /kiosk/<action-name>`, arguments as the JSON BODY. Same shape as
# Kiosk::HotelsController — `ActionController::API` plus `include
# Kiosk::Handler` — with `kind :action` above each declaration, which is what
# puts it on `POST`.
#
# The two writes hand straight to an Operation: `reserve_room` is a transaction
# with a three-part inventory guard and `confirm_booking` one with two gates and
# a COALESCE'd UPDATE, neither of which wants a `render` in the middle.
# `payment_setup` stays HERE because it writes nothing.
#
# Errors are Rails' idiom end to end: the wire's `code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary `render json:,
# status:`. An Operation answers with an {OperationResult} and
# {KioskRefusals#render_operation} is the one place that becomes a status.
#
# Nothing here means a 402. The wire's three payment/PoW codes share that status
# and `Errors::STATUS_CODES` refuses to guess between them; the 402s on this
# origin come from the PoW gates upstream of dispatch, never from a handler.
#
# NOT ROUTABLE — see Kiosk::HotelsController.
class Kiosk::ReservationsController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # payment_setup — canonical skill Step 5 runs this unconditionally before
  # `pay`. With StubPsp (no SetupIntent model) `setup_required?` is always
  # false, so this is an immediate no-op success: {status: "ready"}.
  #
  # POLL CADENCE + STOP CONDITION (K-477/K-595): the wire has no server→assistant
  # push, so an assistant that ever DOES get a `setup_required` learns the human
  # finished only by re-calling this — the descriptor must state a cadence AND a
  # terminal stop condition, or an agent invents its own and polls forever. The
  # cadence below is the skill's verbatim (skill.md Step 5), because the skill is
  # what assistants actually follow. No CHECK COUNT is stated: a count is derived
  # from cadence and horizon, so it goes silently wrong when either moves.
  #
  # getgrocery's descriptor also promises its setup_url is stable across polls
  # (K-492). NOT repeated here: StubPsp mints no setup session, so claiming it
  # would be a claim about code this demo never runs.
  kind :action
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
  # A verb that takes nothing still declares the empty closed object, so "takes
  # no arguments" is a published fact rather than an absence to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # TWO shapes, branching on `status`. A `oneOf` rather than one open object
  # with an optional `setup_url`, because the pairing IS the contract:
  # `setup_required` without a url cannot be acted on. The stub PSP only ever
  # produces the first branch; the second is declared anyway so the published
  # contract matches the other two payment demos.
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
    # From the identity the WIRE resolved; no nil check, because the wire answers
    # 401 itself before dispatch when it cannot resolve one.
    user_id  = kiosk_identity.user_id
    provider = Kiosk.configuration.payment_provider

    if provider.setup_required?(user_id: user_id)
      render json: { status: "setup_required", setup_url: provider.setup_url(user_id: user_id) }
    else
      render json: { status: "ready" }
    end
  end

  # reserve_room — the hold. See {ReserveRoomOperation} for the inventory guard;
  # the two identity values below are read from the identity the wire resolved
  # rather than from arguments, which is what makes a forged `user_id` in the
  # body inert. The descriptor deliberately does NOT promise the hold expires on
  # its own: the deadline is recorded and no sweep enforces it (K-936).
  kind :action
  description "Hold a room for the authenticated principal. It is a HOLD and not a booking: " \
              "nothing is charged and no stay is confirmed until you pay and call " \
              "confirm_booking, and the hold carries a pay-by deadline the operator records " \
              "against it. The answer carries the operator's QUOTE for the whole stay and, in words, the exact " \
              "mandate that quote expects — sign your AP2 cart against it, in this operator's " \
              "currency, at that total, naming this hold. The cashier re-counts both against its own " \
              "quote before it charges anything, so a cart that disagrees is refused outright rather " \
              "than partly honoured. Once the charge is through, `confirm_booking` turns the hold " \
              "into a confirmed stay. There is no room-night in the past to hold: this operator " \
              "holds nothing before tonight, read in the property's own clock (Europe/Istanbul), " \
              "though tonight itself IS bookable."
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
                                 description: "First night (YYYY-MM-DD). Today or later, read in the " \
                                              "property's own clock (Europe/Istanbul)." },
                 check_out:    { type: "string", format: "date",
                                 description: "Checkout day (YYYY-MM-DD, exclusive) — a checkout day " \
                                              "is the next guest's check-in day, so it may equal " \
                                              "another booking's check_in." },
               },
               required: ["property_id", "room_type_id", "check_in", "check_out"]
  output_schema type: "object",
                description: "The hold, and the quote the cart must be signed against.",
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
  # {ConfirmBookingOperation}; the principal is NOT passed in, because both gates
  # express it as a WHERE predicate over `kiosk.current_user_id()`.
  kind :action
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
