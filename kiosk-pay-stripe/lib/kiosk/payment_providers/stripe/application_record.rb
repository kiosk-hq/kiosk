# frozen_string_literal: true

require 'active_record'

module Kiosk
  module PaymentProviders
    class Stripe < Base
      # The base of the adapter's models.
      class ApplicationRecord < ::ActiveRecord::Base
        self.abstract_class = true
      end
    end
  end
end
