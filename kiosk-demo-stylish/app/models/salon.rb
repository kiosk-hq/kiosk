# frozen_string_literal: true

class Salon < ApplicationRecord
  has_many :appointments, dependent: :restrict_with_exception

  def zone = Time.find_zone!(timezone)

  # One sentence for a caller whose clock differs from the salon's now, else nil.
  def timezone_note(caller_zone)
    return if caller_zone.nil?

    gap = zone.now.utc_offset - caller_zone.now.utc_offset
    return if gap.zero?

    hours = format('%g', gap.abs / 3600.0)
    "#{name} runs on #{timezone} time, #{hours} #{hours == '1' ? 'hour' : 'hours'} " \
      "#{gap.positive? ? 'ahead of' : 'behind'} your #{caller_zone.name}. Every hour you book here is on the salon's clock."
  end
end
