# frozen_string_literal: true

# Must precede the adapter require so verify_partial_doubles can see ::Stripe::PaymentIntent at stub time.
require "stripe"
require "kiosk/payment_providers/stripe"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec)   { |c| c.verify_partial_doubles = true }
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.warnings = false

  # The adapter sets `::Stripe.api_key` process-globally in its constructor
  # (stripe.rb). That is the only global state these specs mutate, so restore
  # it around each example to keep leakage between examples out.
  config.around(:each) do |example|
    saved_key = ::Stripe.api_key
    example.run
  ensure
    ::Stripe.api_key = saved_key
  end
end
