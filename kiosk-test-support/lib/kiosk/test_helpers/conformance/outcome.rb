# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      # The result of ONE conformance check.
      #
      # A check never raises to report a failure — it returns an Outcome whose
      # `ok` is false. A raise out of a check means the check itself broke, and
      # the two must stay distinguishable: an operator whose verb is misrouted
      # should read a sentence about their route, not a backtrace through this
      # gem.
      #
      # `message` is the whole of what a test framework shows. It is written as
      # a complete sentence naming what was asserted, what was found, and what
      # to change, because both adapters render it verbatim: the same fault
      # reported through Minitest and through RSpec reads identically, which is
      # what "framework-agnostic" has to cash out as.
      #
      # `details` is a Hash the adapter MAY render and neither currently does.
      # It exists so a caller inspecting an Outcome programmatically — the
      # gem's own suite does — can assert on the facts rather than on the
      # prose.
      Outcome = Data.define(:ok, :check, :subject, :message, :details) do
        def initialize(ok:, check:, subject: nil, message: "", details: {})
          super(ok: ok ? true : false, check: check.to_sym, subject: subject,
                message: message.to_s, details: details || {})
        end

        def ok? = ok

        def failed? = !ok

        def to_s = message
      end

      # Build a passing Outcome.
      def self.pass(check, subject: nil, message: "", details: {})
        Outcome.new(ok: true, check: check, subject: subject,
                    message: message, details: details)
      end

      # Build a failing Outcome.
      def self.fail(check, subject: nil, message: "", details: {})
        Outcome.new(ok: false, check: check, subject: subject,
                    message: message, details: details)
      end
    end
  end
end
