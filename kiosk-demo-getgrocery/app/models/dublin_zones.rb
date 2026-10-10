# frozen_string_literal: true

# The Dublin postal districts getgrocery delivers to. It checks an address's
# form and zone only; whether a plausible address is real only the human knows.
module DublinZones
  # D18, D22 and D24 are deliberately not served.
  SERVED = %w[
    D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17 D20
  ].freeze

  # The clock of each served district.
  ZONES = %w[
    D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17 D20
  ].to_h { |district| [district, "Europe/Dublin"] }.freeze

  Result = Struct.new(:ok, :district, :reason, keyword_init: true) do
    def ok? = ok
  end

  module_function

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
      reason = s.match?(/\bdublin\b/i) ? :no_district : :not_dublin
      return Result.new(ok: false, district: nil, reason: reason)
    end

    unless SERVED.include?(district)
      return Result.new(ok: false, district: district, reason: :out_of_zone)
    end

    Result.new(ok: true, district: district, reason: nil)
  end

  # "Dublin 2", "D02", "D2" or an Eircode routing key ("D02 XY45") → "D02".
  def extract_district(str)
    s = str.to_s
    if (m = s.match(/\bD\s?0?(\d{1,2})\b/i))
      n = m[1].to_i
      return normalise(n)
    end
    if (m = s.match(/\bdublin\s+0?(\d{1,2})\b/i))
      n = m[1].to_i
      return normalise(n)
    end
    nil
  end

  def normalise(n)
    return nil if n < 1 || n > 24

    format("D%02d", n)
  end

  # Why the address is refused, worded to follow its field name.
  def reject_message(result)
    served = SERVED.join(", ")
    case result.reason
    when :blank
      "is missing — getgrocery needs a Dublin delivery address with a postal district " \
        "(e.g. \"42 Camden Street, Dublin 2\") before it can show delivery slots. Ask your " \
        "human for their real address."
    when :no_district
      "names Dublin but no postal district — getgrocery routes by district and needs one " \
        "(e.g. \"Dublin 2\" or an Eircode like \"D02 XY45\"). Served districts: #{served}. " \
        "Ask your human to confirm their real address."
    when :not_dublin
      "is not a Dublin address — getgrocery delivers only within Dublin (served districts " \
        "#{served}). Confirm the real delivery address with your human."
    when :out_of_zone
      "is in #{result.district}, which getgrocery does not deliver to — served districts are " \
        "#{served}. Ask your human for an in-zone Dublin address."
    end
  end
end
