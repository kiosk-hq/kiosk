# frozen_string_literal: true

# A Dublin address in a district this shop delivers to.
class ServedAddressValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, address)
    result = DublinZones.check(address)
    record.errors.add(attribute, DublinZones.reject_message(result)) unless result.ok?
  end
end
