# frozen_string_literal: true

# book_appointment — reserve a salon service for the authenticated visitor, at
# the price the menu quotes TODAY.
#
# Wire-only today: stylish's public page is read-only counts and the staff
# calendar is a query. It is an Operation like its siblings because the seam is
# about where write logic lives, not about how many doors currently reach it —
# and because these three guards are the demo's whole argument (K-692) and a
# guard that `render`s cannot be exercised from a console.
class BookAppointmentOperation
  # @param principal_id [String] the account the wire resolved. NEVER an
  #   argument off the request: `book_appointment` deliberately IGNORES a forged
  #   `user_id` in the body, and it can do that precisely because the value is
  #   passed in from the identity rather than read out of the params.
  #
  #   An INSERT is the one place the principal must be spelled in Ruby. The
  #   queries next door scope with `Appointment.owned_by_current_principal`,
  #   which never names the principal because a WHERE has a predicate to hide it
  #   in; an INSERT has no predicate, so it must supply the value. Both are
  #   un-forgeable for the same reason — the identity is resolved from the Rack
  #   env the wire built, which no request argument can write, and the GUC is set
  #   by SET LOCAL from that same resolved identity — but only the first keeps the
  #   database as the authority. Moving the column's DEFAULT to
  #   `kiosk.current_user_id()` would close the gap; that is a migration, not part
  #   of a handler conversion.
  def self.call(principal_id:, salon_id:, slot:, service_id:)
    # ── Input guards (K-692) ─────────────────────────────────────────────────
    # Refuse with clean 400s instead of letting create! (or the column's NOT
    # NULL) raise a RecordInvalid/NotNullViolation that surfaces as an opaque
    # 500. philslist's `post_listing` is the in-repo model and its reason applies
    # verbatim: the refusal must name what was wrong, and what the valid values
    # are, so an assistant that guessed can recover without fetching the schema
    # first.
    if salon_id.blank?
      return refused("missing field: salon_id — pass the `salon_id` from the `salons` query")
    end
    unless Salon.exists?(id: salon_id)
      return refused("unknown salon_id #{salon_id.inspect} — call the `salons` query for the bookable salons")
    end

    # `slot` needs a guard philslist has no equivalent for, because ActiveRecord's
    # timestamp cast does not fail loudly and fails in TWO different directions:
    # "banana" casts to nil and detonates the column's NOT NULL as a 500, while
    # "next tuesday" casts to TODAY AT MIDNIGHT and was booked silently — a real
    # appointment, in the past, that the agent never asked for. Parse it here,
    # strictly, and say what shape was wanted.
    # THE «e.g.» IS COMPUTED, NOT WRITTEN DOWN (K-972). These two sentences are
    # read by an assistant that is about to retry, so the instant they name has
    # to be one this operation would ACCEPT — a literal is a hint that turns
    # into a second refusal on a day nobody notices, and the guard below refuses
    # anything at or before now. Same instant the catalog's `example_params`
    # publishes, and for the same reason.
    if slot.blank?
      return refused("missing field: slot — an ISO 8601 timestamp, e.g. #{example_slot.inspect}")
    end
    slot_at = begin
      Time.iso8601(slot.to_s)
    rescue ArgumentError, TypeError
      return refused("invalid slot #{slot.inspect} — pass an ISO 8601 timestamp, e.g. #{example_slot.inspect}")
    end

    # ── K-969: AN APPOINTMENT IN THE PAST IS REFUSED ────────────────────────
    # Phil, 2026-08-23: «there should be zero availability for past dates.
    # Booking shouldn't be allowed for those.» The guard above already refuses
    # `"next tuesday"` — but only because it does not PARSE; `"1900-01-01T09:00:00Z"`
    # parses perfectly and booked a real appointment a century ago, which the
    # owner's calendar then rendered as an ordinary row.
    #
    # WHAT «PAST» MEANS HERE, and why it is not hoteling's or getgrocery's rule.
    # Those two verbs take a DATE and sell by the day, so their floor is a day
    # and today counts. This one takes an INSTANT, so its floor is an instant:
    # a slot at or before NOW has passed, and one later today has not. There is
    # no operator timezone to name — an ISO 8601 timestamp WITH an offset is an
    # absolute point and the comparison is exact from any caller's clock. A slot
    # written WITHOUT an offset is read in the app's own zone (UTC here), which
    # is `Time.iso8601`'s published behaviour and is why the refusal echoes back
    # the instant it actually understood.
    #
    # THE READ HALF IS VACUOUS ON THIS DEMO, deliberately: `availability` and
    # `service_menu` publish the SERVICE MENU, not a calendar — this salon
    # overbooks by design and has no finite windows — so there are no dated rows
    # for a past date to appear in and nothing for a read guard to filter. Every
    # slot an assistant proposes here it composed itself, which makes this
    # refusal the only place the floor can live rather than a second line of
    # defence.
    if slot_at <= Time.current
      return refused(
        "slot #{slot_at.iso8601} has already passed — book a time in the future " \
        "(now is #{Time.current.utc.iso8601}); this salon does not record appointments in the past",
      )
    end

    # The chosen service (its price is captured at book time — the menu can change
    # later; the booked price is what the calendar and forecast report).
    # service_id is OPTIONAL — a bare salon_id booking is legitimate and the
    # descriptor says so — but a service_id that names NOTHING must not be
    # silently dropped: that booked an appointment with no service and
    # price_cents NULL, which the owner's revenue forecast then summed as €0
    # while the calendar rendered it as an ordinary row. Nothing surfaced it.
    service = nil
    unless service_id.nil? || service_id.to_s.strip.empty?
      service = Service.find_by(id: service_id)
      unless service
        return refused(
          "unknown service_id #{service_id.inspect} — bookable services: " \
          "#{Service.order(:id).pluck(:id, :name).map { |id, n| "#{id} (#{n})" }.join(', ')}; " \
          "or omit service_id for a bare salon booking",
        )
      end
    end

    # `create!`, NOT `insert!`, and the difference is not taste: stylish never
    # wrote this row in raw SQL, so `create!`'s validations and timestamps are the
    # published behaviour and swapping the writer would change which exception an
    # unrelated bad input raises. A conversion moves code; it does not re-pick the
    # writer.
    appointment = Appointment.create!(
      user_id:     principal_id, # a forged user_id never reaches here
      salon_id:    salon_id,
      slot:        slot_at,
      service_id:  service&.id,
      price_cents: service&.price_cents,
    )

    value = {
      appointment_id: appointment.id,
      salon_id:       appointment.salon_id,
      slot:           appointment.slot.iso8601,
    }
    if service
      value.merge!(
        service:     service.name,
        currency:    "EUR",
        price_cents: service.price_cents,
        price_eur:   service.price_eur,
      )
    end

    OperationResult.ok(value)
  end

  # THE ONE INSTANT THIS DEMO PUBLISHES AS AN EXAMPLE (K-969, K-972).
  #
  # Read from two places that must not disagree: the catalog, through
  # `Kiosk::AppointmentsController`'s `example_params`/`example_row` (a
  # RESOLVABLE slot — see {Kiosk::Server::SchemaSlots}), and the two refusals
  # above, which an assistant reads when it is about to retry. Both are «here
  # is a value that works», so both have to name an instant the guard below
  # would ACCEPT, and a written-down one stops being that on a day nobody
  # notices.
  #
  # A week out at 14:00 UTC: comfortably ahead of NOW from any caller's clock,
  # and a round wall-clock hour so the example reads like something a human
  # asked for.
  #
  # @return [String] an ISO 8601 instant with an offset, always later than now
  def self.example_slot
    (Time.current + 7.days).utc.change(hour: 14).iso8601
  end

  # Every refusal this verb can make is a `bad_request` — see
  # {OperationResult::STATUSES} for why that is a fact about the demo (nothing
  # ever fills up, and the write is caller-scoped by construction) rather than a
  # gap. Written once so the code cannot be spelled differently in four places.
  def self.refused(message)
    OperationResult.refused(code: "bad_request", message: message)
  end
  private_class_method :refused
end
