# frozen_string_literal: true

require 'json'
require 'json_schemer'
require 'openssl'
require 'socket'
require 'uri'
require 'websocket/driver'
require 'kiosk/test_helpers/dpop'

module Kiosk
  module TestHelpers
    class Assistant
      # The assistant's side of `<endpoint>/events`: one WebSocket, subscribed
      # to topics, read until an event arrives.
      #
      #   events = assistant.events(rider)
      #   events.subscribe("kyc_verification")
      #   event = events.await { _1["topic"] == "kyc_verification" }
      #   events.close
      class Events
        class Error < StandardError; end

        # Every way an event's `data` breaks the `payload_schema` the origin serves
        # for its topic, as "topic: error".
        def self.payload_errors(schema_document, events)
          schemas = Array(schema_document['events']).to_h { [it['name'], it['payload_schema']] }
          events.flat_map do |event|
            topic  = event['topic']
            schema = schemas[topic] or next ["#{topic}: this origin serves no such topic"]
            JSONSchemer.schema(schema, meta_schema: 'https://json-schema.org/draft/2020-12/schema')
                       .validate(JSON.parse(JSON.generate(event['data'])))
                       .map { "#{topic}: #{it['error']}" }
          end
        end

        attr_reader :url

        # `key` signs the DPoP proof of the upgrade; its `htu` is the events URL
        # with the HTTP scheme, because the upgrade is an HTTP request there.
        def initialize(base_url:, token:, key:, path: '/kiosk/events', timeout: 10)
          http = URI.join(base_url, path)
          @url = http.to_s.sub(/\Ahttp/, 'ws')
          @io  = open_socket(http.hostname, http.port, http.scheme == 'https')
          @frames = []
          @closed = false
          @driver = start_driver(Dpop.headers(token, key, method: 'GET', url: http.to_s))
          pump(timeout) { @frames.any? { it['type'] == 'welcome' } } || raise(Error, "#{@url} did not welcome the connection")
        end

        # For the driver.
        def write(data) = @io.write(data)

        def subscribe(topic, timeout: 10, **params)
          identifier = { 'channel' => 'KioskEvents', 'topic' => topic }.merge(params.transform_keys(&:to_s))
          @driver.text(JSON.generate('command' => 'subscribe', 'identifier' => JSON.generate(identifier)))
          frame = nil
          pump(timeout) { frame = messages.find { it['type'] == 'subscribed' && it['topic'] == topic } }
          frame || raise(Error, "subscribe to #{topic} was not confirmed")
        end

        def events = messages.select { it.key?('id') && it.key?('topic') }

        def await(timeout: 30, &match) = await_in(:events, timeout, &match)

        # Any message, including frames such as `{"type" => "unsubscribed", "reason" => "reach_revoked"}`.
        def await_message(timeout: 30, &match) = await_in(:messages, timeout, &match)

        # Reads for a fixed time, for asserting what did not arrive.
        def listen(seconds)
          pump(seconds) { false }
          events
        end

        def close
          @io.close
        rescue IOError
          nil
        end

        private

        # A `ping` frame's message is a bare timestamp.
        def messages = @frames.filter_map { it['message'] if it['message'].is_a?(Hash) }

        def await_in(source, timeout, &)
          found = nil
          pump(timeout) { found = send(source).find(&) }
          found || raise(Error, "nothing matching arrived within #{timeout}s")
        end

        def open_socket(host, port, tls)
          tcp = TCPSocket.new(host, port)
          return tcp unless tls

          ssl = OpenSSL::SSL::SSLSocket.new(tcp, OpenSSL::SSL::SSLContext.new.tap(&:set_params))
          ssl.hostname = host
          ssl.sync_close = true
          ssl.connect
          ssl
        end

        def start_driver(headers)
          driver = WebSocket::Driver.client(self)
          headers.each { |name, value| driver.set_header(name, value) }
          driver.on(:message) { @frames << JSON.parse(it.data) }
          driver.on(:close)   { @closed = true }
          driver.on(:error)   { @closed = true }
          driver.start
          driver
        end

        def pump(seconds)
          deadline = Time.now + seconds
          until Time.now > deadline
            return true if yield
            break if @closed

            read_frames if buffered? || @io.wait_readable(0.1)
          end
          yield
        end

        def read_frames
          @driver.parse(@io.read_nonblock(8192))
        rescue IO::WaitReadable
          nil
        rescue IOError, Errno::ECONNRESET
          @closed = true
        end

        # TLS decrypts ahead of the socket.
        def buffered? = @io.is_a?(OpenSSL::SSL::SSLSocket) && @io.pending.positive?
      end
    end
  end
end
