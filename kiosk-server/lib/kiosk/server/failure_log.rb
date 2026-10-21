# frozen_string_literal: true

module Kiosk
  module Server
    # Logs the exception whose message a refusal kept out of the response: Rails' logger, else `warn`.
    # A raising logger is swallowed so one failure does not become two.
    module FailureLog
      # Enough frames to reach the operator's own code without flooding the log.
      BACKTRACE_FRAMES = 20

      # One string to grep for refusals that kept their message off the protocol.
      PREFIX = '[kiosk-server]'

      module_function

      # `summary` is the caller's own words, the half that also reaches the protocol.
      def report(summary, error)
        line = "#{PREFIX} #{summary}: #{error.message}\n  " \
               "#{Array(error.backtrace).first(BACKTRACE_FRAMES).join("\n  ")}"
        logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
        logger ? logger.error(line) : warn(line)
        nil
      rescue StandardError
        nil
      end
    end
  end
end
