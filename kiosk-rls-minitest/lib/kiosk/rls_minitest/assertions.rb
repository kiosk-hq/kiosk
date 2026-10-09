# frozen_string_literal: true

require "minitest/assertions"

module Kiosk
  module RLSMinitest
    # Minitest assertions for the Kiosk error classes; {Kiosk::TestHelpers} mixes them in.
    module Assertions
      def assert_rls_denied(msg = nil, &block)
        assert_raises_kiosk(Kiosk::TestHelpers::Errors::RLSDenied, msg, &block)
      end

      # Errors of other classes propagate unchanged.
      def refute_rls_denied(msg = nil)
        yield
      rescue Kiosk::TestHelpers::Errors::RLSDenied => e
        message = msg || "expected block not to raise RLSDenied, but it did: #{e.message}"
        flunk(message)
      end

      def assert_quota_exceeded(msg = nil, &block)
        assert_raises_kiosk(Kiosk::TestHelpers::Errors::QuotaExceeded, msg, &block)
      end

      def refute_quota_exceeded(msg = nil)
        yield
      rescue Kiosk::TestHelpers::Errors::QuotaExceeded => e
        message = msg || "expected block not to raise QuotaExceeded, but it did: #{e.message}"
        flunk(message)
      end

      private

      def assert_raises_kiosk(klass, msg)
        yield
      rescue klass => e
        e
      rescue StandardError => e
        message = msg || "expected #{klass}, got #{e.class}: #{e.message}"
        flunk(message)
      else
        message = msg || "expected #{klass}, but no exception was raised"
        flunk(message)
      end
    end
  end
end

# Spec-DSL bridges (`proc { ... }.must_raise_rls_denied`), when minitest/spec is loaded.
if defined?(Minitest::Expectations)
  module Minitest::Expectations
    infect_an_assertion :assert_rls_denied,      :must_raise_rls_denied,      :block
    infect_an_assertion :assert_quota_exceeded,  :must_raise_quota_exceeded,  :block
    infect_an_assertion :refute_rls_denied,      :wont_raise_rls_denied,      :block
    infect_an_assertion :refute_quota_exceeded,  :wont_raise_quota_exceeded,  :block
  end
end
