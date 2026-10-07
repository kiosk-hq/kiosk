# frozen_string_literal: true

require "socket"

module Kiosk
  module Redteam
    # A local stripe-mock, Stripe's own fixture server: a demo suite charges and
    # refunds against it with no key and no money moving.
    module StripeMock
      PORT = 12111
      URL  = "http://127.0.0.1:#{PORT}"
      LOG  = "/tmp/stripe-mock.log"

      module_function

      # Reuses one already listening; otherwise spawns one, stopped at exit.
      #
      # @return [String] its base URL
      def start
        return URL if listening?

        abort "stripe-mock not found. Install it: brew install stripe-mock" unless system("command -v stripe-mock >/dev/null 2>&1")

        pid = spawn("stripe-mock", out: LOG, err: LOG)
        at_exit do
          Process.kill("TERM", pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
        30.times { return URL if listening?; sleep 0.3 }
        abort "stripe-mock did not become ready on #{URL} — see #{LOG}"
      end

      def listening?
        TCPSocket.new("127.0.0.1", PORT).close
        true
      rescue StandardError
        false
      end
    end
  end
end
