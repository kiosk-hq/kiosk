# frozen_string_literal: true

# getgrocery's WRITE surface: the four verbs an assistant reaches with
# `POST /kiosk/<action-name>`, arguments as the JSON body. Same shape as
# Kiosk::StorefrontController —
# `ActionController::API` plus `include Kiosk::Handler` — with `kind :action`
# above each declaration, which is what puts it on `POST`.
#
# THE THREE WRITES ARE A HANDFUL OF LINES EACH: read the arguments off the
# request, hand them to an Operation, render what it answers. That is deliberate.
# `create_order` is a six-gate chain that ends in a transaction with a row lock
# in it — the lock the K-544/K-545 pay race is closed by — and a `render` in the
# middle of that is what every earlier slice had to reason about. Moving them to
# app/operations/ is also what makes them callable from anywhere: a console, a
# rake task, and (for the paid-state read they share) the operator's own back
# office at GET /admin/orders.
#
# `payment_setup` deliberately stays HERE. It writes nothing: it asks the
# configured payment provider one question and renders the answer, which is the
# same reason tudu left its queries in the handler — a call plus a literal has
# nothing to extract.
#
# Errors are Rails' idiom end to end: the wire's error-code vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary `render json:,
# status:` naming the code, and the wire re-renders it as the RFC 9457 problem
# document 0.4 answers with — same code, now a top-level member. No Kiosk error
# classes appear below — an Operation answers with an {OperationResult}, and
# {KioskRefusals#render_operation} is the one place that becomes a status. That
# matters more here than on most siblings: `kyc_required` and `forbidden` are
# both 403, so the alcohol age gate is a refusal the STATUS cannot name and only
# the rendered code carries.
#
# Nothing here means a 402. The 402s an assistant meets on this origin come from
# the registration PoW gate (always on) and, when KIOSK_POW_DEMO=1, the catalog
# toll — both upstream of dispatch, never from a handler.
#
# NOT ROUTABLE — see Kiosk::StorefrontController.
class Kiosk::OrdersController < ActionController::API
  include Kiosk::Handler
  include KioskRefusals

  # payment_setup — the card-on-file readiness probe; canonical skill Step 5 runs
  # it before `pay`.
  #
  # POLL CADENCE + STOP CONDITION (K-477): the wire has no server→assistant push,
  # so an assistant learns the human finished the hosted card entry ONLY by
  # re-calling this. The descriptor therefore has to state a cadence AND a
  # terminal stop condition — without one an agent invents its own and can poll
  # forever if the human never completes the step.
  #
  # The cadence here is the skill's, verbatim (skill.md Step 5: ~5 s for the
  # first minute, then ~15 s, give up after ~5 minutes) — the skill is what
  # assistants actually follow, so a descriptor that prescribes anything else is
  # a second, losing instruction. And no CHECK COUNT is stated: a count is
  # derived from the cadence and the horizon, so it silently goes wrong the
  # moment either moves. The horizon is the number an assistant needs.
  #
  # SAFE TO RE-CALL (K-492): the probe is idempotent. When setup is required the
  # Stripe adapter reuses the setup session already outstanding for this
  # principal instead of minting a new one, so every poll returns the SAME
  # setup_url — an assistant relaying the newest url can no longer bounce its
  # human off the page they are filling in.
  kind :action
  description "Check whether the authenticated principal has a saved card on file. " \
              "Returns {status: \"ready\"} if a card is already saved and the assistant can proceed to `pay`. " \
              "Returns {status: \"setup_required\", setup_url: \"…\"} when no card is saved — " \
              "the assistant must hand the setup_url to the human, wait for them to complete the " \
              "Stripe-hosted card entry, then call payment_setup again before paying. " \
              "The assistant should call this before every `pay` invocation on a new device or session. " \
              "POLLING: while your human is at the hosted page, re-check every ~5 seconds for the first " \
              "minute, then every ~15 seconds, and GIVE UP after about 5 minutes — tell your human the " \
              "card setup is still not finished rather than polling indefinitely; they can finish later " \
              "and you re-check then. " \
              "Re-checking is safe and repeatable: while one setup is outstanding this normally returns " \
              "the SAME setup_url, so relay that one link and do NOT send your human a new one per check " \
              "— and if a check ever does come back with a different url, still leave your human on the " \
              "page they already have open unless they tell you it stopped working."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # TWO shapes, and the branch is `status`. Declared as a `oneOf` rather than
  # one open object with an optional `setup_url`, because the pairing is the
  # contract: `setup_required` without a url would be an answer the assistant
  # cannot act on, and `ready` with one would invite it to send its human to a
  # page there is no reason to open.
  output_schema oneOf: [
    { type: "object", additionalProperties: false,
      description: "A card is on file — proceed to `pay`.",
      properties: { status: { const: "ready", description: "ready." } },
      required: ["status"] },
    { type: "object", additionalProperties: false,
      description: "No card on file — the human must complete the hosted card entry first.",
      properties: {
        status:    { const: "setup_required", description: "setup_required." },
        setup_url: { type: "string", description: "The Stripe-hosted card-entry page to hand to your human. Stable across polls while one setup is outstanding — relay this one link rather than a new one per check." },
      },
      required: %w[status setup_url] },
  ]
  def payment_setup
    # The principal, from the identity the WIRE resolved. This used to be a
    # `SELECT kiosk.current_user_id()` round trip followed by a nil check that
    # raised `Unauthenticated` — and that check was UNREACHABLE: the wire resolves
    # an identity before dispatch and answers 401 itself when it cannot, which is
    # exactly what an anonymous probe gets ("no identity resolved from request",
    # never this handler's "no authenticated user"). The round trip and the dead
    # branch go together.
    user_id  = kiosk_identity.user_id
    provider = Kiosk.configuration.payment_provider

    # Key off setup_required? (not saved_method?) so it honours the adapter's
    # policy — incl. KIOSK_TEST_AUTOCARD, where setup is auto-completed at capture
    # and this returns "ready" without a hosted-page round-trip.
    if provider.setup_required?(user_id: user_id)
      render json: { status: "setup_required", setup_url: provider.setup_url(user_id: user_id) }
    else
      render json: { status: "ready" }
    end
  end

  # create_order — the flagship verb. See {CreateOrderOperation} for the six
  # gates; the principal below is read from the identity the wire resolved rather
  # than from arguments. `user_id` is therefore NOT a declared input, and since
  # `input_schema` closes the object (`additionalProperties: false`) and is
  # validated on every 0.4 call, a forged one is refused with a typed 400 naming
  # it — where 0.3 accepted the argument and silently ignored it.
  # ADR-0023: the arguments are declared in `input_schema`, and the pay hint —
  # which spells the expected mandate out in words, entry by entry — is a FIELD
  # of the answer, declared in `output_schema`. This says what an order IS here.
  kind :action
  description "Create a grocery order for the authenticated principal, or REPLACE an unpaid one in " \
              "place — which is how a human changes their mind before any money moves. Delivery is " \
              "part of the order rather than a later step: this origin will not take an order it " \
              "cannot deliver, so a window and an address are required to place one. The answer " \
              "carries the operator's quote and, in words, the exact mandate that quote expects — " \
              "sign your AP2 cart against it, in this operator's currency, mirroring the order line " \
              "for line at catalogue prices and naming the order itself. The cashier re-counts every " \
              "line against its own catalogue before it charges anything, so a cart that disagrees is " \
              "refused outright rather than partly honoured. Alcohol needs a completed 18+ check " \
              "first (`request_kyc`), and asking for it without one is refused rather than quietly " \
              "dropped from the basket."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 items: {
                   type: "array", minItems: 1,
                   description: "The complete cart — products referenced by sku.",
                   items: {
                     type: "object", additionalProperties: false,
                     properties: {
                       sku: { type: "string", description: "Product sku from the catalog query." },
                       qty: { type: "integer", minimum: 1, description: "Quantity." },
                     },
                     required: ["sku", "qty"],
                   },
                 },
                 delivery_slot_id: { type: "integer", minimum: 1, maximum: 6,
                                     description: "The `delivery_slot_id` from a delivery_slots row (1..6)." },
                 delivery_date:    { type: "string",
                                     description: "The `date` (YYYY-MM-DD) of the chosen delivery_slots row, so the booking lands on the day you saw. Optional; omitting books tomorrow." },
                 delivery_address: { type: "string",
                                     description: "In-zone Dublin delivery address naming a served postal district (e.g. \"Dublin 2\" / \"D02\")." },
                 # K-596: `pattern`/`format` so the DECLARED contract carries the shape the
                 # description asserts and the handler enforces (UuidCheck) — a bare
                 # {type:"string"} told an assistant nothing about what "uuid" meant here.
                 order_id:         { type: "string", format: "uuid",
                                     pattern: UuidCheck::JSON_SCHEMA_PATTERN,
                                     description: "Optional uuid of an unpaid order to replace." },
               },
               required: ["items", "delivery_slot_id", "delivery_address"]
  output_schema type: "object",
                description: "The created (or replaced) order, priced.",
                additionalProperties: false,
                properties: {
                  order_id:    { type: "string", description: "uuid. Name it in the cart mandate's `order_id` line item, and pass it to reschedule_delivery as `order_id`." },
                  total_cents: { type: "integer", description: "EUR cents. Sign the cart at exactly this total." },
                  total_eur:   { type: "string", description: "The same total rendered for a human, e.g. \"€12.87\"." },
                  currency:    { type: "string", description: "eur — the currency the cart must be signed in." },
                  slot_at:     { type: "string", description: "The booked delivery window's start instant, ISO 8601 with offset." },
                  pay_hint:    { type: "string", description: "The mandate this order expects, in words." },
                },
                required: %w[order_id total_cents total_eur currency slot_at pay_hint]
  # THE DELIVERY DAY IS RESOLVED, NOT WRITTEN DOWN (K-972) — see
  # {DeliverySlots.example_date}. A literal here published a `delivery_date`
  # the operation refuses as past, which is the one thing an example must not
  # do. `slot_at` is derived from the SAME day and the slot id beside it, so
  # the two halves of the example cannot drift apart either.
  example_params({
    items: [{ sku: "sourdough-bread", qty: 2 }, { sku: "greek-yogurt", qty: 1 }],
    delivery_slot_id: 3,
    delivery_date:    -> { DeliverySlots.example_date.iso8601 },
    delivery_address: "42 Camden Street, Dublin 2",
  })
  example_row({
    order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", total_cents: 1287,
    total_eur: "€12.87", currency: "eur",
    slot_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 3).iso8601 },
    pay_hint: "pay in EUR with a cart mandate whose line_items mirror this order …",
  })
  def create_order
    render_operation CreateOrderOperation.call(
      principal_id:     kiosk_identity.user_id,
      items:            kiosk_plain(params[:items]),
      delivery_slot_id: params[:delivery_slot_id],
      delivery_date:    params[:delivery_date],
      delivery_address: params[:delivery_address],
      order_id:         params[:order_id],
    )
  end

  # reschedule_delivery — move an ALREADY-PAID order's delivery. See
  # {RescheduleDeliveryOperation}.
  # ADR-0023: no call signature. The arguments, and which of them are optional,
  # are declared in `input_schema` below — the literal
  # `reschedule_delivery(a, b[, c[, d]])` this used to carry is the `params:`
  # field ADR-0023 §Decision 4 retired, restated one layer over in prose.
  kind :action
  description "Move an ALREADY-PAID order's delivery to a different window, and optionally to a " \
              "different address. It REUSES the payment already on that order: there is no new " \
              "mandate to sign, nothing new to settle, and no second charge — call it directly, and " \
              "note that re-paying an order that is already settled is refused (403). «Already paid» " \
              "is a PRECONDITION, not an instruction to settle now: an order nobody has paid for " \
              "cannot be rescheduled at all, and is replaced in place with `create_order` instead, " \
              "which stays free until it is paid. One reschedule per order — anything further goes " \
              "through the operator."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 # K-596: same uuid shape as create_order's order_id — see UuidCheck.
                 order_id:         { type: "string", format: "uuid",
                                     pattern: UuidCheck::JSON_SCHEMA_PATTERN,
                                     description: "uuid of the ALREADY-PAID order to reschedule. Its existing payment is reused — do not pay again." },
                 delivery_slot_id: { type: "integer", minimum: 1, maximum: 6,
                                     description: "The new `delivery_slot_id` from a delivery_slots row (1..6)." },
                 delivery_date:    { type: "string",
                                     description: "The `date` (YYYY-MM-DD) of the chosen delivery_slots row. Optional; omitting books tomorrow." },
                 delivery_address: { type: "string",
                                     description: "Optional new in-zone Dublin delivery address; unchanged if omitted." },
               },
               required: ["order_id", "delivery_slot_id"]
  # No price and no pay_hint, and that absence is the contract: a reschedule
  # REUSES the order's existing payment, so there is no new mandate to sign.
  output_schema type: "object",
                description: "The rescheduled order.",
                additionalProperties: false,
                properties: {
                  order_id:       { type: "string", description: "The order that moved, echoed." },
                  rescheduled_at: { type: "string", description: "The NEW delivery window's start instant, ISO 8601 with offset." },
                },
                required: %w[order_id rescheduled_at]
  # Resolved for {DeliverySlots.example_date}'s reason (K-972): a literal
  # `delivery_date` here published a reschedule the operation refuses.
  example_params({ order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e", delivery_slot_id: 3,
                   delivery_date: -> { DeliverySlots.example_date.iso8601 } })
  example_row({ order_id: "e2b1c0d4-5f6a-4b3c-8d2e-1f0a9b8c7d6e",
                rescheduled_at: -> { DeliverySlots.slot_at(DeliverySlots.example_date, 3).iso8601 } })
  def reschedule_delivery
    render_operation RescheduleDeliveryOperation.call(
      order_id:         params[:order_id],
      delivery_slot_id: params[:delivery_slot_id],
      delivery_date:    params[:delivery_date],
      delivery_address: params[:delivery_address],
    )
  end

  # request_kyc — open an 18+ verification at the broker. See
  # {RequestKycOperation}.
  kind :action
  description "Start an 18+ verification for the authenticated principal — needed only to order " \
              "alcohol, and for nothing else on this shelf. The answer carries a broker page to relay " \
              "to your human: an anonymizing KYC broker confirms the fact and signs an attestation " \
              "for it, and never hands this operator the documents behind it. Once the human has " \
              "approved, `kyc_status` is where the signed attestation appears; submit it to " \
              "`POST <endpoint>/agents/kyc`, then place the order again. No pre-shared issuer key is " \
              "needed. At most three verifications may be pending for one account at a time — a " \
              "fourth is refused until one of them finishes, and a request that has been approved " \
              "or declined stops counting, so poll `kyc_status` rather than opening another."
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

  # The wire's own JSON, back out of Rails' params wrapper.
  #
  # `params` wraps every nested object in ActionController::Parameters, which is
  # NOT a Hash — and `items` is the one argument on this origin whose ELEMENT
  # TYPE the handler decides on: {WireArguments.items} answers a typed 400 for an
  # element that is not a {sku, qty} object (K-693), and under the wrapper EVERY
  # element would fail that test, including the happy path's. So the wrapper is
  # removed HERE, where it comes from, rather than teaching an Operation about a
  # controller type.
  #
  # This is NOT the K-765 contortion the fleet declined. That row is about the
  # `.inspect` SPELLING of a nested value inside an error message, which is
  # cosmetic and is left faithful on this demo too (an object-shaped `order_id`
  # or `delivery_date` still renders as Rails spells it). This one is control
  # flow: without it the flagship verb refuses its own happy path.
  def kiosk_plain(value)
    case value
    when ActionController::Parameters then value.to_unsafe_h.deep_symbolize_keys
    when Array                        then value.map { |element| kiosk_plain(element) }
    else value
    end
  end
end
