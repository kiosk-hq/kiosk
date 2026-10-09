# frozen_string_literal: true

module Kiosk
  module RLS
    # One PostgreSQL row-level-security policy: `using` filters reads, `check` writes.
    Policy = Data.define(:name, :action, :using, :check) do
      ACTIONS = %i[select insert update delete all].freeze

      def initialize(name:, action:, using: nil, check: nil)
        action = action.to_sym
        unless ACTIONS.include?(action)
          raise ArgumentError,
                "action must be one of #{ACTIONS.inspect}, got #{action.inspect}"
        end

        if using.nil? && check.nil?
          raise ArgumentError, "at least one of using:/check: required"
        end

        super(
          name:   name.to_s,
          action: action,
          using:  using && using.to_s,
          check:  check && check.to_s,
        )
      end
    end
  end
end
