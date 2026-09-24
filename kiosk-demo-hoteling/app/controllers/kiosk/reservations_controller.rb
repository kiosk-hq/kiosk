# frozen_string_literal: true

# hoteling's WRITE surface: the three verbs an assistant reaches with
# `POST /kiosk/<action-name>`, arguments as the JSON BODY. Same shape as
# Kiosk::HotelsController — `ActionController::API` plus `include
# Kiosk::Handler` — with `kind :action` above each declaration, which is what
# puts it on `POST`.
#
# `reserve_room` hands straight to an Operation: a transaction with a three-part
# inventory guard, which does not want a `render` in the middle. `confirm_booking`
# hands to one too, for the gates rather than for a write — it reads the
# property's answer. `payment_setup` stays HERE because it writes nothing.
#
# Errors are Rails' idiom end to end: the wire's `code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary `render json:,
# status:`. An Operation answers with an {OperationResult} and
# {KioskRefusals#render_operation} is the one place that becomes a status.
#
# Nothing here means a 402. The wire's three payment/PoW codes share that status
# and `Errors::STATUS_CODES` refuses to guess between them; the 402s on this
# origin come from the PoW gates upstream of dispatch, never from a handler.
class Kiosk::ReservationsController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # payment_setup — canonical skill Step 5 runs this unconditionally before
  # `pay`. With StubPsp (no SetupIntent model) `setup_required?` is always
  # false, so this is an immediate no-op success: {status: "ready"}.
  #
  # POLL CADENCE + STOP CONDITION: the wire has no server→assistant
  # push, so an assistant that ever DOES get a `setup_required` learns the human
  # finished only by re-calling this — the descriptor must state a cadence AND a
  # terminal stop condition, or an agent invents its own and polls forever. The
  # cadence below is the skill's verbatim (skill.md Step 5), because the skill is
  # what assistants actually follow. No CHECK COUNT is stated: a count is derived
  # from cadence and horizon, so it goes silently wrong when either moves.
  # ── WHAT THIS ORIGIN PUSHES ───────────────────────────────────────────────
  #
  # A booking can be paid BY SOMEBODY ELSE. The cashier deliberately lets
  # principal B settle A's booking — that is a documented property of this
  # demo, not an accident — and until now the only way A learned of it was to
  # re-read `my_bookings` on a guess. The subject is the booking and the
  # audience is its OWNER, never the payer: B already knows it paid.
  #
  # `subject_reachable` is re-run while the subscription stands, with no
  # request and therefore no GUC, so it calls {Booking.readable_by?} rather
  # than the per-request isolation scope beside it.
  # THE PROPERTY'S OWN ANSWER, and the clearest case on this wire for a stream.
  # Every other transition here is something the caller asked for; this one is
  # not. The guest has paid and is waiting on a hotel desk, so there is no call
  # to re-try and no cadence to invent — the operator answers when it answers,
  # and sometimes the answer is no and the money goes back.
  topic :booking_confirmation do
    description "The property answered your paid booking: confirmed, with the code to give at " \
                "the desk — or cancelled, in which case the charge has been reversed to the card " \
                "that paid and the room-nights are free again. This is the answer; " \
                "confirm_booking reads it back and mints nothing."
    payload_schema type: "object", additionalProperties: false,
                   properties: { booking_id:        { type: "string", format: "uuid" },
                                 status:            { enum: %w[confirmed cancelled] },
                                 confirmation_code: { type: "string" },
                                 reason:            { type: "string" },
                                 refund:            { type: "object", additionalProperties: false,
                                                      description: "Present when money had been " \
                                                                   "taken and has been sent back.",
                                                      properties: {
                                                        amount_cents:  { type: "integer" },
                                                        currency:      { type: "string" },
                                                        psp_reference: { type: "string" },
                                                        reverses:      { type: "string",
                                                                         description: "The charge " \
                                                                           "this reversal undid." },
                                                      } } },
                   required: %w[booking_id status]
    subject_reachable ->(booking_id, identity) { Booking.readable_by?(booking_id, identity.user_id) }
  end

  topic :booking_payment do
    description "A booking of yours was paid — possibly by somebody else settling it on " \
                "your behalf. Confirm it once this says `paid`."
    payload_schema type: "object", additionalProperties: false,
                   properties: { booking_id:    { type: "string", format: "uuid" },
                                 payment_state: { enum: %w[paid] } },
                   required: %w[booking_id payment_state]
    subject_reachable ->(booking_id, identity) { Booking.readable_by?(booking_id, identity.user_id) }
  end

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
  # its own: the deadline is recorded and no sweep enforces it.
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
              "holds nothing before tonight, read in THE PROPERTY's own clock — a fact about the " \
              "hotel and not about this operator, published as `timezone` on a hotel_detail row — " \
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
                                 description: "First night (YYYY-MM-DD). Today or later, read in THIS " \
                                              "PROPERTY's own clock (`hotel_detail` publishes it as " \
                                              "`timezone`). A calendar day is never converted." },
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

  # confirm_booking — READS the property's answer. It writes nothing: a guest
  # does not confirm their own booking, a hotel does, and {PropertyDecisionJob}
  # is the only thing that mints a confirmation code. See
  # {ConfirmBookingOperation}; the principal is NOT passed in, because the
  # ownership test is a WHERE predicate over `kiosk.current_user_id()`.
  kind :action
  description "Collect the property's answer to a booking you have paid for. THE HOTEL " \
              "CONFIRMS, NOT YOU: paying starts it deciding, and it answers on its own clock — " \
              "minutes, not milliseconds — so this call is forbidden with «the property has not " \
              "answered yet» until it has, and forbidden naming the reversed charge if the " \
              "property could not honour the booking. On an accepted booking it returns the " \
              "`confirmation_code` the hotel stored — the reference the guest gives at the desk, " \
              "the same one my_bookings lists. Do not poll this: subscribe to the " \
              "`booking_confirmation` topic on this origin's event stream instead."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 booking_id: { type: "string", format: "uuid",
                               description: "The booking to collect the answer for — a " \
                                            "`booking_id` from reserve_room or my_bookings, " \
                                            "verbatim; it must belong to the principal and be " \
                                            "paid." },
               },
               required: ["booking_id"]
  output_schema type: "object",
                description: "The confirmed booking and the desk reference the property stored.",
                additionalProperties: false,
                properties: {
                  booking_id:        { type: "string", description: "The booking that was confirmed, echoed." },
                  status:            { const: "confirmed", description: "confirmed." },
                  confirmation_code: { type: "string", description: "The reference the guest gives at the desk — minted by the property, not by this call. Durable: my_bookings lists the same code, and reading it again returns the same one." },
                },
                required: %w[booking_id status confirmation_code]
  def confirm_booking
    render_operation ConfirmBookingOperation.call(booking_id: params[:booking_id])
  end
end
