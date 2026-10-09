# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "uri"

module Kiosk
  module TestHelpers
    # A local stripe-mock, Stripe's own fixture server: a demo suite charges and
    # refunds against it with no key and no money moving.
    #
    # stripe-mock answers every confirmed PaymentIntent `requires_payment_method`
    # with nothing received. A small front on {PORT} passes everything through
    # to it and answers a confirmed create as Stripe does for a test card:
    # `succeeded`, the whole amount received.
    module StripeMock
      PORT          = 12111
      UPSTREAM_PORT = 12112
      URL           = "http://127.0.0.1:#{PORT}"
      LOG           = "/tmp/stripe-mock.log"
      DROPPED       = %w[accept-encoding connection content-length host transfer-encoding].freeze

      module_function

      # Reuses a front already listening; otherwise spawns stripe-mock and the
      # front, stopped at exit.
      #
      # @return [String] the front's base URL
      def start
        return URL if listening?

        abort "stripe-mock not found. Install it: brew install stripe-mock" unless system("command -v stripe-mock >/dev/null 2>&1")

        pids = []
        pids << spawn("stripe-mock", "-http-port", UPSTREAM_PORT.to_s, out: LOG, err: LOG) unless listening?(UPSTREAM_PORT)
        pids << spawn(RbConfig.ruby, "-I", File.expand_path("../..", __dir__), "-rkiosk/test_helpers/stripe_mock",
                      "-e", "Kiosk::TestHelpers::StripeMock.serve", out: LOG, err: LOG)
        at_exit do
          pids.each do |pid|
            Process.kill("TERM", pid)
            Process.wait(pid)
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          end
        end
        30.times { return URL if listening? && listening?(UPSTREAM_PORT); sleep 0.3 }
        abort "stripe-mock did not become ready on #{URL} — see #{LOG}"
      end

      def listening?(port = PORT)
        TCPSocket.new("127.0.0.1", port).close
        true
      rescue StandardError
        false
      end

      # Runs the front until killed.
      def serve
        server = TCPServer.new("127.0.0.1", PORT)
        loop { Thread.new(server.accept) { |client| relay(client) } }
      end

      def relay(client)
        method, path = client.gets.to_s.split
        return unless path # a readiness check connects and hangs up

        headers = {}
        while (line = client.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.strip
        end
        body = client.read(headers["content-length"].to_i)

        upstream = Net::HTTP.start("127.0.0.1", UPSTREAM_PORT) do |http|
          http.send_request(method, path, body, headers.except(*DROPPED))
        end
        answer = upstream.body.to_s
        answer = settled(answer) if method == "POST" && path == "/v1/payment_intents" &&
                                    URI.decode_www_form(body.to_s).to_h["confirm"] == "true"

        client.write("HTTP/1.1 #{upstream.code} #{upstream.message}\r\n")
        upstream.each_header { |k, v| client.write("#{k}: #{v}\r\n") unless DROPPED.include?(k) || k == "content-encoding" }
        client.write("content-length: #{answer.bytesize}\r\nconnection: close\r\n\r\n#{answer}")
      ensure
        client.close
      end

      def settled(answer)
        intent = JSON.parse(answer)
        return answer unless intent["object"] == "payment_intent"

        JSON.generate(intent.merge("status" => "succeeded", "amount_received" => intent["amount"]))
      end
    end
  end
end
