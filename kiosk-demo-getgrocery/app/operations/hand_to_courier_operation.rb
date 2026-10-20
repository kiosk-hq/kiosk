# frozen_string_literal: true

# Moves a paid basket from the shop to the courier. True for the run that
# hands it over; false when the courier already has it.
class HandToCourierOperation
  def self.call(order)
    # Two dispatch runs can read the order before either saves it. The row lock
    # makes them take turns, so the second one reads `out_for_delivery`.
    order.with_lock do
      next false unless order.awaiting_courier?

      order.update!(status: :out_for_delivery)
    end
  end
end
