# frozen_string_literal: true

require "test_helper"

# WHAT THIS SHOP KEEPS OUT OF ITS REQUEST LOG.
#
# Rails writes the `Parameters:` line at `info`, which is the level a deployed
# demo runs at, so every argument a verb declares is written down unless the
# app says otherwise. `delivery_address` is a customer's postal address — it
# arrives on `create_order`, on `reschedule_delivery` and from the storefront
# form — and it is this shop's own field, not the wire's: kiosk-server filters
# the wire's credential-bearing fields from its own initializer, and an
# operator's domain field is the operator's to name.
#
# The assertion runs the app's real `config.filter_parameters` through the
# filter Rails builds from it, which is the object that renders that line.
class FilteredParametersTest < ActiveSupport::TestCase
  def filtered(params)
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)
  end

  test "delivery_address is masked" do
    assert_equal "[FILTERED]", filtered("delivery_address" => "99 Sentinel Street, Dublin 2")["delivery_address"]
  end

  # The control: without it the assertion above would also pass on a filter
  # that masks everything.
  test "sku is left in the clear — a catalogue reference is nobody's personal data" do
    assert_equal "sourdough-bread", filtered("sku" => "sourdough-bread")["sku"]
  end
end
