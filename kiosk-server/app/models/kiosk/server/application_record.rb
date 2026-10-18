# frozen_string_literal: true

module Kiosk
  module Server
    # The base of the engine's models.
    class ApplicationRecord < ::ActiveRecord::Base
      self.abstract_class = true
    end
  end
end
