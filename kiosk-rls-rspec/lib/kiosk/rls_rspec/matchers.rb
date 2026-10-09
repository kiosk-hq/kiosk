# frozen_string_literal: true

require "rspec/expectations"

# `expect { ... }.to be_rls_denied`
RSpec::Matchers.define :be_rls_denied do
  supports_block_expectations

  match do |block|
    block.call
    false
  rescue Kiosk::TestHelpers::Errors::RLSDenied
    true
  rescue StandardError => e
    @other_error = e
    false
  end

  failure_message do
    if @other_error
      "expected block to raise Kiosk::TestHelpers::Errors::RLSDenied, " \
        "but raised #{@other_error.class}: #{@other_error.message}"
    else
      "expected block to raise Kiosk::TestHelpers::Errors::RLSDenied, but it didn't"
    end
  end

  failure_message_when_negated do
    "expected block not to raise Kiosk::TestHelpers::Errors::RLSDenied, but it did"
  end
end

# `expect { ... }.to be_quota_exceeded`
RSpec::Matchers.define :be_quota_exceeded do
  supports_block_expectations

  match do |block|
    block.call
    false
  rescue Kiosk::TestHelpers::Errors::QuotaExceeded
    true
  rescue StandardError => e
    @other_error = e
    false
  end

  failure_message do
    if @other_error
      "expected block to raise Kiosk::TestHelpers::Errors::QuotaExceeded, " \
        "but raised #{@other_error.class}: #{@other_error.message}"
    else
      "expected block to raise Kiosk::TestHelpers::Errors::QuotaExceeded, but it didn't"
    end
  end

  failure_message_when_negated do
    "expected block not to raise Kiosk::TestHelpers::Errors::QuotaExceeded, but it did"
  end
end
