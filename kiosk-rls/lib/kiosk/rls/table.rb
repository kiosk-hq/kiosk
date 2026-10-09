# frozen_string_literal: true

require "kiosk/rls/policy"

module Kiosk
  module RLS
    # The builder an `enable_rls_on TABLE do ... end` block runs in.
    class Table
      attr_reader :name, :policies, :comment_text, :app_role, :sequences

      def initialize(name, app_role: nil, sequences: [])
        @name         = name.to_s
        @policies     = []
        @comment_text = nil
        @app_role     = app_role || Kiosk.configuration.app_role
        @sequences    = Array(sequences).map(&:to_s)
      end

      def policy(action, name: nil, using: nil, check: nil)
        @policies << Policy.new(
          name:   name || default_policy_name(action),
          action: action,
          using:  using,
          check:  check,
        )
      end

      # Mandatory; emitted as COMMENT ON TABLE.
      def comment(text)
        @comment_text = text&.to_s
      end

      def validate!
        if @comment_text.nil? || @comment_text.empty?
          raise ArgumentError,
                "enable_rls_on(:#{@name}) requires a `comment \"...\"` " \
                "inside the block"
        end
        self
      end

      private

      def default_policy_name(action)
        "#{@name}_#{action}"
      end
    end
  end
end
