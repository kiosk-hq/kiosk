# frozen_string_literal: true

require "socket"

# Start (or reuse) a local `stripe-mock` — Stripe's own fixture server, the same
# one getgrocery's adversarial rake tasks use (`lib/tasks/demo.rake`).
#
# stripe-mock is STATELESS: it answers from the OpenAPI fixtures, it does not
# remember what you created. That bounds what it can prove — see the stripe-mock
# group in `stripe_setup_reuse_spec.rb`.
module StripeMock
  PORT = 12111
  URL  = "http://127.0.0.1:#{PORT}"

  module_function

  def reachable?
    socket = TCPSocket.new("127.0.0.1", PORT)
    socket.close
    true
  rescue StandardError
    false
  end

  def installed?
    system("command -v stripe-mock >/dev/null 2>&1")
  end

  # The base URL, or nil when stripe-mock is neither running nor installed
  # (CI's gems matrix does not install it — see the K-candidate in the K-492
  # notes; examples that need it skip rather than pretend).
  def start
    return URL if reachable?
    return nil unless installed?

    pid = spawn("stripe-mock", out: File::NULL, err: File::NULL)
    at_exit do
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    30.times do
      return URL if reachable?

      sleep 0.2
    end
    nil
  end
end
