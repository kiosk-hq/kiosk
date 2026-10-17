# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      # The result of one check. A failure is returned, never raised; `message` is
      # the sentence both adapters render, `details` the facts behind it.
      Outcome = Data.define(:ok, :check, :subject, :message, :details) do
        def ok? = ok

        def failed? = !ok
      end

      def self.pass(check, **) = outcome(true, check, **)

      def self.fail(check, **) = outcome(false, check, **)

      def self.outcome(passed, check, subject: nil, message: '', details: {})
        Outcome.new(ok: passed, check: check.to_sym, subject: subject,
                    message: message.to_s, details: details || {})
      end
      private_class_method :outcome
    end
  end
end
