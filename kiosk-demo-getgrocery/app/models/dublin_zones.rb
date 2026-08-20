# frozen_string_literal: true

# ── Dublin delivery-zone validation (ADDRESS-UPFRONT, K-468) ──────────────────
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
#     providing/confirming the address (that is the skill's job, K-468). This
#     structural gate adds realism and catches gross fakes; it is not, and
#     cannot be, proof the address exists.
#
# A "zone" is a Dublin postal district: the routing-key form `D01`..`D24`
# (even districts to `D24`; odd to `D20` plus the special even ones), the
# spoken form `Dublin 2`, or the Eircode routing-key prefix embedded in the
# address (`D02 XY45` → district `D02`). getgrocery serves the inner + inner-
# suburban districts below; the far outer districts are intentionally NOT
# served so the out-of-zone path is demonstrable.
module DublinZones
  # Served Dublin postal districts (routing-key form, zero-padded two digits).
  # A deliberately partial list: D18/D22/D24 (outer suburbs) are NOT served, so
  # an in-Dublin-but-out-of-zone address is demonstrable.
  SERVED = %w[
    D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17 D20
  ].freeze

  # A parsed, validated result. `ok:` true only when a served district was
  # found. `zone` is the canonical `D0N` routing key (nil when not resolvable).
  Result = Struct.new(:ok, :zone, :reason, keyword_init: true) do
    def ok? = ok
  end

  module_function

  # Parse a free-text delivery address (or a bare zone/postcode string) and
  # decide whether it names a SERVED Dublin district.
  #
  #   DublinZones.check("42 Camden Street, Dublin 2")        # ok,  zone "D02"
  #   DublinZones.check("5 Rock Rd, Dublin 4, D04 XY45")     # ok,  zone "D04"
  #   DublinZones.check("Dublin 24")                         # out-of-zone (D24 not served)
  #   DublinZones.check("123 Demo Street, Dublin")           # malformed (no district)
  #   DublinZones.check("10 Downing St, London")             # out-of-zone (not Dublin)
  #
  # @return [Result]
  def check(address)
    s = address.to_s.strip
    return Result.new(ok: false, zone: nil, reason: :blank) if s.empty?

    zone = extract_zone(s)
    if zone.nil?
      # No Dublin district anywhere in the string. Distinguish "names Dublin but
      # gave no district" from "not a Dublin address at all" for a clearer hint.
      reason = s.match?(/\bdublin\b/i) ? :no_district : :not_dublin
      return Result.new(ok: false, zone: nil, reason: reason)
    end

    unless SERVED.include?(zone)
      return Result.new(ok: false, zone: zone, reason: :out_of_zone)
    end

    Result.new(ok: true, zone: zone, reason: nil)
  end

  # Extract a canonical `D0N` routing key from an address, or nil.
  # Accepts: "Dublin 2", "Dublin D2", "D02", "D2", or an Eircode routing key
  # embedded as the first token (`D02 XY45`). District 0 is invalid.
  def extract_zone(str)
    s = str.to_s
    # Eircode / routing-key form: D02, D6W-style single/double digit at a word
    # boundary (D6W is a real half-district but we normalise to D06 family — for
    # the demo we only match the numeric districts).
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
    served = "#{SERVED.first}–#{SERVED.last} (inner Dublin)"
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
      "delivery_address is in #{result.zone}, which getgrocery does not deliver to — " \
        "served districts are #{served}. Ask your human for an in-zone Dublin address."
    else
      "delivery_address is not a served Dublin address (served districts #{served})."
    end
  end
end
