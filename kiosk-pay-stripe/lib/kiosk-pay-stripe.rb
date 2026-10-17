# rubocop:disable Naming/FileName -- Bundler.require loads the file named after the gem.
# frozen_string_literal: true

# Convenience entry — `require "kiosk-pay-stripe"` mirrors the gem name.
require 'kiosk/payment_providers/stripe'
# rubocop:enable Naming/FileName
