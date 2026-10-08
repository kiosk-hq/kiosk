# frozen_string_literal: true

# The write verbs. The work is in app/operations.
class Kiosk::RentalsController < ActionController::API
  include Kiosk::Handler

  topic :booking_payment do
    description "A reservation of yours was paid — possibly by somebody else settling it on " \
                "your behalf. Activate the rental once this says `paid`."
    payload_schema type: "object", additionalProperties: false,
                   properties: { reservation_id: { type: "string", format: "uuid" },
                                 payment_state:  { enum: %w[paid] } },
                   required: %w[reservation_id payment_state]
    subject_reachable ->(reservation_id, identity) { Reservation.readable_by?(reservation_id, identity.user_id) }
  end

  # What both rental verbs answer.
  RENTAL = {
    type: "object",
    description: "The activated rental and the unlock link to hand to your human.",
    additionalProperties: false,
    properties: {
      scooter_code: { type: "string", description: "The vehicle this rental is for." },
      rental_token: { type: "string",
                      description: "An Ed25519-signed OFFLINE unlock token for the vehicle named beside it, " \
                                   "short-lived and good once. It is presented AT the vehicle — the App Clip " \
                                   "writes it to the lock — and the lock checks it without reaching this " \
                                   "origin. Nothing on this wire opens a lock: that step is physical, and it " \
                                   "is the human's." },
      unlock_url:   { type: "string", format: "uri",
                      description: "The page to hand your human, complete and verbatim, as you hand a " \
                                   "card-setup link. It shows rental_token and its QR: scanning that QR, or " \
                                   "tapping the vehicle's NFC tag, opens the App Clip that writes the token " \
                                   "to the lock. It CARRIES the token, so it is a credential and not a " \
                                   "pointer: hand it over once." },
      exp:          { type: "integer", description: "Unix seconds at which the token stops being accepted." },
    },
    required: %w[scooter_code rental_token unlock_url exp],
  }.freeze

  kind :action
  description "Hold one fleet vehicle for the authenticated principal. Rentals here are METERED by " \
              "the minute, so what is settled up front is a single minute at that vehicle's rate — " \
              "the hold is what the money is for, not the whole ride. The answer carries the " \
              "operator's quote and, in words, the exact mandate that quote expects: sign your AP2 " \
              "cart against it, in this operator's currency, at that total, naming this hold. The " \
              "cashier re-counts both against its own quote before it charges anything, so a cart " \
              "that disagrees is refused outright rather than partly honoured. Reserving is open to " \
              "EVERY vehicle, licence-free and licence-required alike — whether you may ride the one " \
              "you booked is decided later, by the verb that activates the rental and issues its token: " \
              "start_rental for a licence-free scooter, rent_motorcycle for a licence-required one."
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
    render json: ReserveOperation.call(principal_id: kiosk_identity.user_id, scooter_code: params[:scooter_code])
  end

  kind :action
  description "Verify gates (ownership, licence-free vehicle, payment) and issue an Ed25519 offline rental token for a licence-free scooter (no KYC). " \
              "The reservation must be PAID first: reserve, then pay as reserve's pay_hint says, then call this. " \
              "Refuses a KYC-gated motorcycle (needs_licence in scooters_available) — use rent_motorcycle for those"
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 reservation_id: { type: "string", format: "uuid",
                                   description: "The reservation to activate — a `reservation_id` from " \
                                                "reserve or my_reservations, verbatim." },
               },
               required: ["reservation_id"]
  output_schema(**RENTAL)
  def start_rental
    render json: StartRentalOperation.call(reservation_id: params[:reservation_id])
  end

  kind :action
  description "Rent a combustion-engine motorcycle — KYC-gated on age_over_18 AND licence_a (category-A licence); issues an Ed25519 offline rental token. " \
              "The reservation must be PAID first: reserve, then pay as reserve's pay_hint says, then call this."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 reservation_id: { type: "string", format: "uuid",
                                   description: "The motorcycle reservation to activate — a " \
                                                "`reservation_id` from reserve or my_reservations, verbatim." },
               },
               required: ["reservation_id"]
  output_schema(**RENTAL)
  def rent_motorcycle
    render json: RentMotorcycleOperation.call(reservation_id: params[:reservation_id])
  end

end
