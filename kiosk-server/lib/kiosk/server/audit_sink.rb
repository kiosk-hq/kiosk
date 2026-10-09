# frozen_string_literal: true

require "kiosk/server/action_event"

module Kiosk
  module Server
    # Hands one {ActionEvent} per action invocation, success or failure, to the
    # operator's `c.audit_sink` callable; with no sink nothing is built or stored.
    # Queries, `pay` and refusals before an action ran are not emitted.
    #
    #   Kiosk.configure do |c|
    #     c.audit_sink = ->(event) { AuditLog.create!(**event.to_h) }
    #   end
    #
    # Called after the action's transaction has closed; a sink that raises is
    # logged and never fails the action.
    module AuditSink
      class << self
        def configured? = !Kiosk.configuration.audit_sink.nil?

        def emit(event, sink: Kiosk.configuration.audit_sink)
          return false if sink.nil?

          sink.call(event)
          true
        rescue StandardError => e
          report(event, e)
          false
        end

        private

        def report(event, error)
          message = "[kiosk-server] audit_sink raised for action " \
                    "#{event.action.inspect}: #{error.class}: #{error.message}"
          logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
          logger ? logger.error(message) : warn(message)
        rescue StandardError
          nil
        end
      end
    end
  end
end
