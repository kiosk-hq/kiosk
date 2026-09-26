# frozen_string_literal: true

# ── Dublin delivery-zone validation (ADDRESS-UPFRONT) ─────────────────────────
#
# getgrocery delivers only within a set of served Dublin postal districts. The
# delivery address is a REQUIRED, EARLY input: `delivery_slots` cannot return
# slots (and `create_order` cannot place an order) without an in-zone address,
# so an assistant must obtain the address from its human BEFORE it can shop.
#
# HONEST SCOPE — what this can and cannot do:
#   • It CAN reject a malformed address (no Dublin postal district) and an
#     out-of-zone one (a district getgrocery does not serve, or a non-Dublin
#     city) with a clean 400 telling the assistant what is needed.
#   • It CANNOT tell whether a plausible in-zone address is REAL. "42 Camden
#     Street, Dublin 2" and "1 Nonexistent Way, Dublin 2" both pass — there is
#     no address-book lookup here. Catching a *fabricated but plausible* address
#     is beyond any format/zone check; the only real defense is the HUMAN
#     providing/confirming the address (that is the skill's job). This
#     structural gate adds realism and catches gross fakes; it is not, and
#     cannot be, proof the address exists.
#
# A "zone" is a Dublin postal district: the routing-key form `D01`..`D24`
# (even districts to `D24`; odd to `D20` plus the special even ones), the
# spoken form `Dublin 2`, or the Eircode routing-key prefix embedded in the
# address (`D02 XY45` → district `D02`). getgrocery serves the inner + inner-
# suburban districts below; the far outer districts are intentionally NOT
# served so the out-of-zone path is demonstrable.
#
# That sentence explains the module's NAME and nothing else. The VALUE this
# module resolves an address to is spelled `district` everywhere it is named —
# the `Result` member, {.extract_district}, {WireArguments.served_district} and
# the wire field `delivery_slots` publishes — because the row's `timezone` in
# this same demo is the CLOCK the window is written in, and one word for a
# routing key and a clock is unreadable three lines apart. The area sense ("in-zone",
# "out-of-zone") keeps the word: an address is inside or outside the served
# area, which is not a value anything reads off a row.
module DublinZones
  # Served Dublin postal districts (routing-key form, zero-padded two digits).
  # A deliberately partial list: D18/D22/D24 (outer suburbs) are NOT served, so
  # an in-Dublin-but-out-of-zone address is demonstrable.
  SERVED = %w[
    D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17 D20
  ].freeze

  # ── THE CLOCK OF EACH DISTRICT THIS SHOP DELIVERS TO ────────────────────
  #
  # A delivery happens AT THE DOOR, so the wall clock a window is offered on
  # belongs to the delivery ADDRESS — the district it routed to — and not to
  # this operator. Every district getgrocery serves today is in Dublin, so the
  # map has one value; what matters is that it is a map, declared per served
  # district, rather than one constant for the origin. A shop that opened a
  # depot in another country would add a row here and every window it offered
  # there would be right without touching a verb.
  #
  # DECLARED, NEVER INFERRED. The zone is not derived from the district string,
  # from a postcode range or from anything else about the address: a guess
  # nobody wrote down is one nobody can check from the other side of the wire.
  # A district absent from this map has no clock and is not deliverable, which
  # {SERVED} already prevents — spec/delivery_slots_spec.rb holds the two
  # lists equal.
  ZONES = %w[
    D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17 D20
  ].to_h { |district| [district, "Europe/Dublin"] }.freeze

  # A parsed, validated result. `ok:` true only when a served district was
  # found. `district` is the canonical `D0N` routing key (nil when not resolvable).
  Result = Struct.new(:ok, :district, :reason, keyword_init: true) do
    def ok? = ok
  end

  module_function

  # The IANA zone a delivery to this district is timed on, or nil for one this
  # shop does not serve. The caller has always established the district is
  # served before it asks.
  def zone_name_for(district)
    ZONES[district]
  end

  # Parse a free-text delivery address (or a bare district/postcode string) and
  # decide whether it names a SERVED Dublin district.
  #
  #   DublinZones.check("42 Camden Street, Dublin 2")        # ok,  district "D02"
  #   DublinZones.check("5 Rock Rd, Dublin 4, D04 XY45")     # ok,  district "D04"
  #   DublinZones.check("Dublin 24")                         # out-of-zone (D24 not served)
  #   DublinZones.check("123 Demo Street, Dublin")           # malformed (no district)
  #   DublinZones.check("10 Downing St, London")             # out-of-zone (not Dublin)
  #
  # @return [Result]
  def check(address)
    s = address.to_s.strip
    return Result.new(ok: false, district: nil, reason: :blank) if s.empty?

    district = extract_district(s)
    if district.nil?
      # No Dublin district anywhere in the string. Distinguish "names Dublin but
      # gave no district" from "not a Dublin address at all" for a clearer hint.
      reason = s.match?(/\bdublin\b/i) ? :no_district : :not_dublin
      return Result.new(ok: false, district: nil, reason: reason)
    end

    unless SERVED.include?(district)
      return Result.new(ok: false, district: district, reason: :out_of_zone)
    end

    Result.new(ok: true, district: district, reason: nil)
  end

  # Extract a canonical `D0N` routing key from an address, or nil.
  # Accepts: "Dublin 2", "Dublin D2", "D02", "D2", or an Eircode routing key
  # embedded as the first token (`D02 XY45`). District 0 is invalid.
  def extract_district(str)
    s = str.to_s
    # Eircode / routing-key form: D02, D2, D 2 — the numeric districts only.
    # The half-district D6W is not matched at all, so {check} answers it
    # :not_dublin rather than out-of-zone.
    if (m = s.match(/\bD\s?0?(\d{1,2})\b/i))
      n = m[1].to_i
      return normalise(n)
    end
    # Spoken form: "Dublin 2", "Dublin 24".
    if (m = s.match(/\bdublin\s+0?(\d{1,2})\b/i))
      n = m[1].to_i
      return normalise(n)
    end
    nil
  end

  # 1..24 → "D01".."D24"; anything else (0, >24) is not a real district.
  def normalise(n)
    return nil if n < 1 || n > 24

    format("D%02d", n)
  end

  # Human-readable, assistant-actionable reason for a rejection. Names WHAT is
  # needed so the assistant knows to go back to its human for a real address.
  def reject_message(result)
    served = SERVED.join(", ")
    case result.reason
    when :blank
      "missing delivery_address — getgrocery needs a Dublin delivery address " \
        "with a postal district (e.g. \"42 Camden Street, Dublin 2\") before it " \
        "can show delivery slots. Ask your human for their real address."
    when :no_district
      "delivery_address names Dublin but no postal district — getgrocery routes " \
        "by district and needs one (e.g. \"Dublin 2\" or an Eircode like \"D02 XY45\"). " \
        "Served districts: #{served}. Ask your human to confirm their real address."
    when :not_dublin
      "delivery_address is not a Dublin address — getgrocery delivers only within " \
        "Dublin (served districts #{served}). Confirm the real delivery address with your human."
    when :out_of_zone
      "delivery_address is in #{result.district}, which getgrocery does not deliver to — " \
        "served districts are #{served}. Ask your human for an in-zone Dublin address."
    else
      "delivery_address is not a served Dublin address (served districts #{served})."
    end
  end
end
