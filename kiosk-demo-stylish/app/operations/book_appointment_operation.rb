# frozen_string_literal: true

# book_appointment — reserve a salon service for the authenticated visitor, at
# the price the menu quotes TODAY.
#
# Wire-only today (stylish's page is read-only counts), an Operation anyway: a
# guard that `render`s cannot be exercised from a console or reused by a second
# door, and these three guards are the demo's whole argument.
class BookAppointmentOperation
  # @param principal_id [String] the account the wire resolved. NEVER an argument
  #   off the request: `book_appointment` IGNORES a forged `user_id` in the body,
  #   and can do that precisely because the value comes from the identity.
  #
  #   An INSERT is the one place the principal must be spelled in Ruby: the
  #   queries next door hide it in `Appointment.owned_by_current_principal`'s
  #   WHERE predicate, an INSERT has none. Moving the column's DEFAULT to
  #   `kiosk.current_user_id()` would keep the database the authority; a migration.
  def self.call(principal_id:, salon_id:, slot:, service_id:)
    # ── Input guards ─────────────────────────────────────────────────────────
    # Clean 400s instead of letting `create!` (or the column's NOT NULL) raise a
    # RecordInvalid/NotNullViolation that surfaces as an opaque 500. Each refusal
    # names what was wrong and what the valid values are, so an assistant that
    # guessed can recover without fetching the schema first.
    if salon_id.blank?
      return refused("missing field: salon_id — pass the `salon_id` from the `salons` query")
    end
    unless Salon.exists?(id: salon_id)
      return refused("unknown salon_id #{salon_id.inspect} — call the `salons` query for the bookable salons")
    end

    # `slot` needs its own guard because ActiveRecord's timestamp cast does not
    # fail loudly and fails in TWO directions: "banana" casts to nil and detonates
    # the column's NOT NULL as a 500, while "next tuesday" casts to TODAY AT
    # MIDNIGHT and books a real appointment in the past. The «e.g.» is COMPUTED:
    # a written-down instant becomes a second refusal once it ages.
    if slot.blank?
      return refused("missing field: slot — an ISO 8601 timestamp, e.g. #{example_slot.inspect}")
    end

    # ── THE CLOCK IS THIS SALON'S ────────────────────────────────────────────
    #
    # The salon has already been established to exist, two guards up, so this
    # reads the zone of the chair actually being booked rather than one constant
    # for the whole origin. It decides how the instant is READ BACK — in a
    # refusal, in the confirmation, and in every later listing of this row.
    zone = SalonClock.zone_for(salon_id)

    # A `date-time` argument is an RFC 3339 timestamp and RFC 3339 REQUIRES the
    # offset, so a value without one is not of the declared type at all. It is
    # refused rather than completed on ANY clock: completing it at the salon
    # ignores the caller that told us its own, and completing it at the caller's
    # would need a header this verb does not read. An appointment booked an hour
    # off is unrecoverable; a refusal naming its remedy is not.
    if SalonClock.zoneless?(slot)
      return refused(
        "slot #{slot.inspect} names no time zone — an appointment is an INSTANT, so pass an " \
        "ISO 8601 timestamp carrying its offset, e.g. #{example_slot.inspect}. This salon's own " \
        "clock is #{zone.name}; sending \"…T14:00:00\" would leave two readings of one booking " \
        "and nothing to say which one you meant.",
      )
    end

    slot_at = begin
      SalonClock.parse_slot(slot, zone)
    rescue ArgumentError, TypeError
      return refused("invalid slot #{slot.inspect} — pass an ISO 8601 timestamp, e.g. #{example_slot.inspect}")
    end

    # ── An appointment in the past is refused ───────────────────────────────
    # The guard above only catches what does not PARSE; `"1900-01-01T09:00:00Z"`
    # parses perfectly and would book a real appointment a century ago.
    #
    # This verb takes an INSTANT rather than a date, so its floor is an instant:
    # at or before NOW has passed, later today has not. An instant carries its
    # own offset — the guard above refuses one that does not — so the comparison
    # is exact from any caller's clock and needs no zone at all. What the zone
    # decides is how the refusal READS BACK: on THIS SALON's clock, so a caller
    # that meant another hour can see which one it got. No read-side
    # counterpart, deliberately: `availability` publishes the service MENU, not
    # a calendar, so there are no dated rows to filter and this is the only
    # place the floor can live.
    if slot_at <= Time.current
      return refused(
        "slot #{SalonClock.publish(slot_at, zone)} has already passed — book a time in the future " \
        "(now is #{SalonClock.publish(Time.current, zone)}); this salon does not record appointments in the past",
      )
    end

    # The price is captured at book time — the menu can change later. `service_id`
    # is OPTIONAL, but one that names NOTHING must not be silently dropped: that
    # booked an appointment with a NULL price which the revenue forecast summed as
    # €0 while the calendar rendered it as an ordinary row.
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

    # `create!`, NOT `insert!`: stylish never wrote this row in raw SQL, so
    # `create!`'s validations and timestamps are the published behaviour and
    # swapping the writer would change which exception a bad input raises.
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
      slot:           SalonClock.publish(appointment.slot, zone),
      timezone:       zone.name,
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

  # The one instant this demo publishes as an example, read from two places that
  # must not disagree: the catalog's `example_params`/`example_row` and the two
  # `slot` refusals above. Both mean «here is a value that works», so both must
  # name an instant this guard would ACCEPT. A week out at 14:00 on the salon's
  # own clock — ahead of now from any caller's clock, on a round wall-clock hour.
  #
  # The zone is a salon's, not UTC, because this is the «copy this» value: an
  # operator copying it should carry away the RULE and not just the shape, and
  # the rule is that the salon's clock is the one that decides ({SalonClock}).
  # Rendered on a salon's clock the example is the same kind of value the verb
  # answers WITH, so the example and the response agree. It is the ORIGIN
  # DEFAULT here because a published example addresses no salon: the descriptor
  # is one document for every salon this origin books.
  #
  # AND THE SENTENCE ABOVE IS TRUE OF THE CLOCK AS WELL AS THE INSTANT, which
  # takes work on the response side: an `ActiveSupport::TimeWithZone` rendered
  # straight off the record goes out through `Time.zone`, so a confirmation
  # built that way answers `Z` beside a `+02:00` example. Every published
  # instant in this demo goes through {SalonClock.publish} instead, because the
  # demo's own invariant is that the salon's clock decides, and a response on a
  # different clock from the example is the reader's first reason to doubt it.
  #
  # @return [String] an ISO 8601 instant carrying the salon's own offset,
  #   always later than now
  def self.example_slot
    SalonClock.default_zone.now.advance(days: 7).change(hour: 14).iso8601
  end

  # Every refusal this verb can make is a `bad_request` — see
  # {OperationResult::STATUSES} for why that is a fact about the demo, not a gap.
  def self.refused(message)
    OperationResult.refused(code: "bad_request", message: message)
  end
  private_class_method :refused
end
