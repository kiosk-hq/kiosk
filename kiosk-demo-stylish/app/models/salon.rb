# frozen_string_literal: true

class Salon < ApplicationRecord
  has_many :appointments, dependent: :restrict_with_exception

  def zone = Time.find_zone!(timezone)

  # The clock gap and whose clock the answer is on, for a caller on another clock now; else nil.
  def timezone_note(caller_zone)
    gap = Kiosk.clock_gap_note(name, zone, caller_zone)
    "#{gap} Every hour you book here is on the salon's clock." if gap
  end
end
