# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      # The result of one check. A failure is returned, never raised; `message` is
      # the sentence both adapters render, `details` the facts behind it.
      Outcome = Data.define(:ok, :check, :subject, :message, :details) do
        def initialize(ok:, check:, subject: nil, message: "", details: {})
          super(ok: ok ? true : false, check: check.to_sym, subject: subject,
                message: message.to_s, details: details || {})
        end

        def ok? = ok

        def failed? = !ok
      end

      def self.pass(check, subject: nil, message: "", details: {})
        Outcome.new(ok: true, check: check, subject: subject,
                    message: message, details: details)
      end

      def self.fail(check, subject: nil, message: "", details: {})
        Outcome.new(ok: false, check: check, subject: subject,
                    message: message, details: details)
      end
    end
  end
end
