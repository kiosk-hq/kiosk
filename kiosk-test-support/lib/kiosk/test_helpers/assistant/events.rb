# frozen_string_literal: true

require "json"
require "json_schemer"
require "openssl"
require "socket"
require "uri"
require "websocket/driver"

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
          schemas = Array(schema_document["events"]).to_h { [_1["name"], _1["payload_schema"]] }
          events.flat_map do |event|
            topic  = event["topic"]
            schema = schemas[topic] or next ["#{topic}: this origin serves no such topic"]
            JSONSchemer.schema(schema, meta_schema: "https://json-schema.org/draft/2020-12/schema")
                       .validate(JSON.parse(JSON.generate(event["data"])))
                       .map { "#{topic}: #{_1["error"]}" }
          end
        end

        attr_reader :url

        def initialize(base_url:, token:, path: "/kiosk/events", timeout: 10)
          uri  = URI(base_url)
          tls  = uri.scheme == "https"
          @url = "#{tls ? "wss" : "ws"}://#{uri.host}:#{uri.port}#{path}"
          @io  = open_socket(uri.host, uri.port, tls)
          @frames = []
          @closed = false
          @driver = WebSocket::Driver.client(self)
          @driver.set_header("Authorization", "Bearer #{token}")
          @driver.on(:message) { @frames << JSON.parse(_1.data) }
          @driver.on(:close)   { @closed = true }
          @driver.on(:error)   { @closed = true }
          @driver.start
          pump(timeout) { @frames.any? { _1["type"] == "welcome" } } || raise(Error, "#{@url} did not welcome the connection")
        end

        # For the driver.
        def write(data) = @io.write(data)

        def subscribe(topic, timeout: 10, **params)
          identifier = { "channel" => "KioskEvents", "topic" => topic }.merge(params.transform_keys(&:to_s))
          @driver.text(JSON.generate("command" => "subscribe", "identifier" => JSON.generate(identifier)))
          frame = nil
          pump(timeout) { frame = messages.find { _1["type"] == "subscribed" && _1["topic"] == topic } }
          frame || raise(Error, "subscribe to #{topic} was not confirmed")
        end

        def events = messages.select { _1.key?("id") && _1.key?("topic") }

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
        def messages = @frames.filter_map { _1["message"] if _1["message"].is_a?(Hash) }

        def await_in(source, timeout, &match)
          found = nil
          pump(timeout) { found = send(source).find(&match) }
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

        def pump(seconds)
          deadline = Time.now + seconds
          until Time.now > deadline
            return true if yield
            break if @closed
            next unless buffered? || IO.select([@io], nil, nil, 0.1)

            begin
              @driver.parse(@io.read_nonblock(8192))
            rescue IO::WaitReadable
              next
            rescue EOFError, IOError, Errno::ECONNRESET
              @closed = true
            end
          end
          yield
        end

        # TLS decrypts ahead of the socket.
        def buffered? = @io.is_a?(OpenSSL::SSL::SSLSocket) && @io.pending.positive?
      end
    end
  end
end
