# frozen_string_literal: true

# The morning delivery to the shop (config/recurring.yml runs it).
class RestockJob < ApplicationJob
  queue_as :default

  def perform = Product.restock!
end
