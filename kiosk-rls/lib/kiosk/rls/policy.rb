# frozen_string_literal: true

module Kiosk
  module RLS
    # Value object representing one PostgreSQL row-level-security policy
    # declaration.
    #
    # See design spec §7 «RLS DSL».
    #
    # @!attribute [r] name
    #   The policy name as it lives in `pg_policy` (e.g. `rentals_select`).
    # @!attribute [r] action
    #   One of `:select`, `:insert`, `:update`, `:delete`, `:all`.
    # @!attribute [r] using
    #   The `USING (...)` predicate (read-side filter). nil if not applicable.
    # @!attribute [r] check
    #   The `WITH CHECK (...)` predicate (write-side filter). nil if not
    #   applicable.
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
