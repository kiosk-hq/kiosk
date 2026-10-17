# frozen_string_literal: true

# A stay at a property: the checkout after the first night, and no night before
# tonight on the property's own clock. Today is bookable.
class StayValidator < ActiveModel::Validator
  def validate(record)
    return if record.check_in.nil? || record.check_out.nil?

    record.errors.add(:check_out, 'must be after check_in') unless record.check_out > record.check_in
    refuse_past_check_in(record) if record.property
  end

  private

  def refuse_past_check_in(record)
    zone = record.property.zone
    return if record.check_in >= zone.today

    record.errors.add(:check_in, "#{record.check_in.iso8601} is in the past — the earliest night this hotel " \
                                 "sells is #{zone.today.iso8601} (#{zone.name})")
  end
end
