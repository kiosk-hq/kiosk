# frozen_string_literal: true

require 'json'
require 'net/http'
require 'socket'
require 'uri'

module Kiosk
  module TestHelpers
    # A local stripe-mock for demo suites. A front on {url} relays to it and
    # answers two calls as Stripe does where stripe-mock does not: a confirmed
    # PaymentIntent create with a test card is `succeeded`, fully received, and
    # a refund that names no charge is a 400.
    module StripeMock
      LOG           = '/tmp/stripe-mock.log'
      DROPPED       = %w[accept-encoding connection content-length host transfer-encoding].freeze
      NO_CHARGE_BODY = JSON.generate(error: {
                                       type: 'invalid_request_error',
                                       message: 'One of the following params should be provided for this request: ' \
                                                'payment_intent or charge.'
                                     })
      NO_CHARGE = "HTTP/1.1 400 Bad Request\r\ncontent-type: application/json\r\n" \
                  "content-length: #{NO_CHARGE_BODY.bytesize}\r\nconnection: close\r\n\r\n#{NO_CHARGE_BODY}".freeze

      module_function

      # The front's base URL: STRIPE_MOCK_URL when set, else a free port held
      # for the life of this process. A suite that spawns its front stops it at
      # exit, so each concurrent suite runs its own.
      def url = @url ||= ENV.fetch('STRIPE_MOCK_URL') { "http://127.0.0.1:#{free_port}" }

      # Reuses a front already listening on {url}; otherwise spawns stripe-mock
      # and the front, stopped at exit.
      #
      # @return [String] the front's base URL
      def start
        return url if listening?(port)

        abort 'stripe-mock not found. Install it: brew install stripe-mock' unless system('command -v stripe-mock >/dev/null 2>&1')

        upstream = free_port
        pids = spawn_processes(upstream)
        at_exit { pids.each { stop(it) } }
        await_ready(upstream)
      end

      def port = URI(url).port

      def free_port = TCPServer.open('127.0.0.1', 0) { it.addr[1] }

      def spawn_processes(upstream)
        [spawn('stripe-mock', '-http-port', upstream.to_s, out: LOG, err: LOG),
         spawn(RbConfig.ruby, '-I', File.expand_path('../..', __dir__), '-rkiosk/test_helpers/stripe_mock',
               '-e', "Kiosk::TestHelpers::StripeMock.serve(#{port}, #{upstream})", out: LOG, err: LOG)]
      end

      def stop(pid)
        Process.kill('TERM', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def await_ready(upstream)
        30.times do
          return url if listening?(port) && listening?(upstream)

          sleep 0.3
        end
        abort "stripe-mock did not become ready on #{url} — see #{LOG}"
      end

      def listening?(port)
        TCPSocket.new('127.0.0.1', port).close
        true
      rescue StandardError
        false
      end

      # Runs the front until killed.
      def serve(port, upstream)
        @upstream = upstream
        server = TCPServer.new('127.0.0.1', port)
        loop { Thread.new(server.accept) { |client| relay(client) } }
      end

      def relay(client)
        method, path = client.gets.to_s.split
        return unless path # a readiness check connects and hangs up

        headers  = read_headers(client)
        body     = client.read(headers['content-length'].to_i)
        return client.write(NO_CHARGE) if chargeless_refund?(method, path, body)

        relay_upstream(client, method, path, body, headers)
      ensure
        client.close
      end

      def relay_upstream(client, method, path, body, headers)
        upstream = forward(method, path, body, headers)
        answer   = upstream.body.to_s
        answer = settled(answer) if confirmed_create?(method, path, body)
        respond(client, upstream, answer)
      end

      def chargeless_refund?(method, path, body)
        params = URI.decode_www_form(body.to_s).to_h
        method == 'POST' && path == '/v1/refunds' && params['payment_intent'].to_s.empty? && params['charge'].to_s.empty?
      end

      def forward(method, path, body, headers)
        Net::HTTP.start('127.0.0.1', @upstream) do |http|
          http.send_request(method, path, body, headers.except(*DROPPED))
        end
      end

      def read_headers(client)
        headers = {}
        while (line = client.gets) && line != "\r\n"
          name, value = line.split(':', 2)
          headers[name.downcase] = value.strip
        end
        headers
      end

      def confirmed_create?(method, path, body)
        method == 'POST' && path == '/v1/payment_intents' &&
          URI.decode_www_form(body.to_s).to_h['confirm'] == 'true'
      end

      def respond(client, upstream, answer)
        client.write("HTTP/1.1 #{upstream.code} #{upstream.message}\r\n")
        upstream.each_header { |k, v| client.write("#{k}: #{v}\r\n") unless DROPPED.include?(k) || k == 'content-encoding' }
        client.write("content-length: #{answer.bytesize}\r\nconnection: close\r\n\r\n#{answer}")
      end

      def settled(answer)
        intent = JSON.parse(answer)
        return answer unless intent['object'] == 'payment_intent'

        JSON.generate(intent.merge('status' => 'succeeded', 'amount_received' => intent['amount']))
      end
    end
  end
end
