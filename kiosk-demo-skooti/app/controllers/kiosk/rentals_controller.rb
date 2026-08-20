# frozen_string_literal: true

# skooti's WRITE surface: the five verbs an assistant reaches with
# `POST /kiosk/<action-name>`, one endpoint per verb, arguments as the JSON body
# (protocol 0.4 deleted the multiplexed `POST /kiosk/run`).
# Same shape as Kiosk::FleetController — `ActionController::API`
# plus `include Kiosk::Action` — because a controller declares queries OR
# actions, never both.
#
# THE FOUR WRITES ARE THREE LINES EACH: read the arguments off the request, hand
# them to an Operation, render what it answers. That is deliberate. `start_rental`
# and `rent_motorcycle` are gate chains that end in an Ed25519 signature and a
# status flip, and `request_kyc` is a server-to-server call followed by an
# INSERT; a `render` in the middle of any of them is what the earlier slices had
# to reason about, and moving them to app/operations/ is what makes them callable
# from anywhere — a console, a rake task, or a second surface if skooti ever
# grows one (POST /kyc/callback is NOT one: see {RequestKycOperation}).
#
# `payment_setup` deliberately stays HERE. It writes nothing: it asks the
# configured payment provider one question and renders the answer, which is the
# same reason tudu left its queries in the handler — a call plus a literal has
# nothing to extract.
#
# Errors are Rails' idiom end to end: the wire's `code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary `render json:,
# status:` naming the code, and the wire carries it verbatim. No Kiosk error
# classes appear below — an Operation answers with an {OperationResult}, and
# {KioskRefusals#render_operation} is the one place that becomes a status. That
# matters more here than on the sibling demos: `kyc_required` and `forbidden` are
# both 403, so `rent_motorcycle`'s Gate 0 is a refusal the STATUS cannot name and
# only the rendered code carries.
#
# Nothing here means a 402. The 402s an assistant meets on this origin come from
# the registration PoW gate (always on), upstream of dispatch, never from a
# handler.
#
# NOT ROUTABLE — see Kiosk::FleetController.
class Kiosk::RentalsController < ActionController::API
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
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # TWO shapes, and the branch is `status`. Declared as a `oneOf` rather than
  # one open object with an optional `setup_url`, because the pairing is the
  # contract. This demo's stub PSP only ever produces the first branch — the
  # second is declared anyway, so the PUBLISHED contract is the same across all
  # three payment demos.
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

  # reserve — the hold, and the quote a cart must be signed against. See
  # {ReserveOperation}; the principal below is the only thing this controller
  # contributes, and it is read from the identity the wire resolved rather than
  # from arguments, which is what makes a forged `user_id` in the body inert.
  # ADR-0023: the answer's fields, and the pay hint that spells the expected
  # mandate out in words, are declared in `output_schema`. This says what a
  # reservation IS and what it is priced on.
  description "Hold one fleet vehicle for the authenticated principal. Rentals here are METERED by " \
              "the minute, so what is settled up front is a single minute at that vehicle's rate — " \
              "the hold is what the money is for, not the whole ride. The answer carries the " \
              "operator's quote and, in words, the exact mandate that quote expects: sign your AP2 " \
              "cart against it, in this operator's currency, at that total, naming this hold. The " \
              "cashier re-counts both against its own quote before it charges anything, so a cart " \
              "that disagrees is refused outright rather than partly honoured. Reserving is open to " \
              "EVERY vehicle, licence-free and licence-required alike — whether you may ride the one " \
              "you booked is decided later, by the verb that unlocks it."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 scooter_code: { type: "string",
                                 description: "Vehicle code from a scooters_available row, e.g. \"SK-001\"." },
               },
               required: ["scooter_code"]
  output_schema type: "object",
                description: "The hold, and the quote the cart must be signed against.",
                additionalProperties: false,
                properties: {
                  reservation_id:      { type: "string", description: "uuid. Name it in the cart mandate's line item, and pass it to start_rental / rent_motorcycle as `reservation_id`." },
                  scooter_code:        { type: "string", description: "The vehicle held, echoed." },
                  price_per_min_cents: { type: "integer", description: "EUR cents — the quoted UPFRONT MINUTE, which is the cart's total." },
                  currency:            { type: "string", description: "eur — the currency the cart must be signed in." },
                  pay_hint:            { type: "string", description: "The mandate this hold expects, in words." },
                },
                required: %w[reservation_id scooter_code price_per_min_cents currency pay_hint]
  example_params({ scooter_code: "SK-001" })
  example_row({
    reservation_id: "a3f9c1e2-7b4d-4e8a-9c1f-2d6e5b0a3c7f",
    scooter_code: "SK-001", price_per_min_cents: 15, currency: "eur",
    pay_hint: "pay in EUR with a cart mandate whose total_amount_cents == 15 …",
  })
  def reserve
    return unless kiosk_given?(:scooter_code)

    render_operation ReserveOperation.call(
      principal_id: kiosk_identity.user_id,
      scooter_code: params[:scooter_code],
    )
  end

  # start_rental — the licence-FREE path. See {StartRentalOperation} for the
  # gates; note that no `scooter_code` is accepted, by design.
  description "Verify gates (ownership, licence-free vehicle, payment) and issue an Ed25519 offline rental token for a licence-free scooter (no KYC). " \
              "Refuses a KYC-gated motorcycle (needs_licence in scooters_available) — use rent_motorcycle for those"
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 reservation_id: { type: "string", format: "uuid",
                                   description: "The reservation to activate — a `reservation_id` from " \
                                                "reserve or my_reservations, verbatim." },
               },
               required: ["reservation_id"]
  # The SAME three fields rent_motorcycle answers with: both verbs end in one
  # activation ({RentalActivation}), and two verbs that share a code path must
  # not publish two different result contracts.
  output_schema type: "object",
                description: "The activated rental and its offline unlock token.",
                additionalProperties: false,
                properties: {
                  scooter_code: { type: "string", description: "The vehicle unlocked." },
                  rental_token: { type: "string", description: "An Ed25519-signed OFFLINE unlock token — present it to the vehicle; it verifies without reaching this origin." },
                  exp:          { type: "integer", description: "Unix seconds at which the token stops being accepted." },
                },
                required: %w[scooter_code rental_token exp]
  def start_rental
    render_operation StartRentalOperation.call(reservation_id: params[:reservation_id])
  end

  # rent_motorcycle — the KYC-gated path. See {RentMotorcycleOperation}; Gate 0
  # runs before the argument guards and that ordering is published behaviour.
  description "Rent a combustion-engine motorcycle — KYC-gated on age_over_18 AND licence_a (category-A licence); issues an Ed25519 offline rental token"
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 reservation_id: { type: "string", format: "uuid",
                                   description: "The motorcycle reservation to activate — a " \
                                                "`reservation_id` from reserve or my_reservations, verbatim." },
               },
               required: ["reservation_id"]
  # Identical to start_rental's: both verbs end in the same activation
  # ({RentalActivation}). What differs between them is the GATE, not the answer.
  output_schema type: "object",
                description: "The activated rental and its offline unlock token.",
                additionalProperties: false,
                properties: {
                  scooter_code: { type: "string", description: "The vehicle unlocked." },
                  rental_token: { type: "string", description: "An Ed25519-signed OFFLINE unlock token — present it to the vehicle; it verifies without reaching this origin." },
                  exp:          { type: "integer", description: "Unix seconds at which the token stops being accepted." },
                },
                required: %w[scooter_code rental_token exp]
  def rent_motorcycle
    render_operation RentMotorcycleOperation.call(reservation_id: params[:reservation_id])
  end

  # request_kyc — open a verification at the broker. See {RequestKycOperation}.
  description "Start the age-18-or-over and category-A driving-licence verification for the " \
              "authenticated principal — needed only to ride a licence-required motorcycle, never for " \
              "a licence-free scooter. The answer carries a broker page to relay to your human: an " \
              "anonymizing KYC broker confirms both facts and signs an attestation for them, and " \
              "never hands this operator the documents behind them. Once the human has approved, " \
              "`kyc_status` is where the signed attestation appears; submit it to " \
              "`POST <endpoint>/agents/kyc`, then ask for the motorcycle again. No pre-shared issuer " \
              "key is needed."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "object",
                description: "The opened verification.",
                additionalProperties: false,
                properties: {
                  request_id:       { type: "string", description: "Pass to kyc_status as `request_id` to poll for the signed attestation." },
                  verification_url: { type: "string", description: "The broker page to relay to your human to approve." },
                  status:           { const: "pending", description: "pending — a freshly opened request is always this." },
                },
                required: %w[request_id verification_url status]
  def request_kyc
    render_operation RequestKycOperation.call(principal_id: kiosk_identity.user_id)
  end

  private

  # Was the argument SUPPLIED AT ALL — a different question from "is it usable",
  # and the only one that cannot be asked anywhere but here.
  #
  # `reserve` distinguishes an ABSENT `scooter_code` ("missing field:
  # scooter_code") from one that is present and null or empty ("scooter not
  # found: "), because the raw handler asked `args.fetch(:scooter_code) { raise }`
  # — a question about the request ENVELOPE, which an Operation taking a plain
  # value cannot answer: nil-because-absent and nil-because-null arrive
  # identically. `params.key?` is the same question in the same place. Written as
  # a guard clause —
  #
  #   return unless kiosk_given?(:scooter_code)
  #
  # — so the refusal is already rendered when the action returns.
  #
  # `reservation_id` and `request_id` deliberately do NOT go through this: those
  # verbs asked `blank?`, which collapses absent, null, "" and `false` into one
  # answer, so their guard belongs with the value, in {WireArguments}.
  def kiosk_given?(field)
    return true if params.key?(field)

    render_refusal(WireArguments.missing(field.to_s))
    false
  end
end
