# frozen_string_literal: true

require "json"
require "openssl"
require "socket"
require "uri"
require "websocket/driver"

module Kiosk
  module Redteam
    # The assistant's side of `<endpoint>/events`: one WebSocket, subscribed to
    # topics, read until an event arrives.
    #
    #   stream = Kiosk::Redteam::EventStream.new(base_url: "http://127.0.0.1:3001", token: token)
    #   stream.subscribe("kyc_verification")
    #   # … act …
    #   event = stream.await { |e| e["topic"] == "kyc_verification" }
    #   stream.close
    #
    # The scheme decides TLS, as it does for {Wire.http_for}.
    class EventStream
      # Raised when the origin refuses the socket or a subscription, or when
      # nothing satisfying the wait arrives in time.
      class Error < StandardError; end

      attr_reader :url

      # @param base_url [String] the origin, e.g. "https://getgrocery.demo.kiosk.tech"
      # @param token    [String] the bearer the HTTP calls carry
      # @param path     [String] the events path under the origin
      def initialize(base_url:, token:, path: "/kiosk/events", timeout: 10)
        uri  = URI(base_url)
        tls  = uri.scheme == "https"
        @url = "#{tls ? "wss" : "ws"}://#{uri.host}:#{uri.port}#{path}"
        @io  = open_socket(uri.host, uri.port, tls)
        @frames = []
        @closed = false
        @driver = WebSocket::Driver.client(self)
        @driver.set_header("Authorization", "Bearer #{token}")
        @driver.on(:message) { |e| @frames << JSON.parse(e.data) }
        @driver.on(:close)   { @closed = true }
        @driver.on(:error)   { @closed = true }
        @driver.start
        pump(timeout) { @frames.any? { |f| f["type"] == "welcome" } } ||
          raise(Error, "#{@url} did not welcome the connection")
      end

      # Called by the driver.
      def write(data) = @io.write(data)

      # Subscribes and waits for the `subscribed` frame.
      #
      # @return [Hash] that frame
      def subscribe(topic, timeout: 10, **params)
        identifier = { "channel" => "KioskEvents", "topic" => topic }.merge(params.transform_keys(&:to_s))
        @driver.text(JSON.generate("command" => "subscribe", "identifier" => JSON.generate(identifier)))
        frame = nil
        pump(timeout) do
          frame = messages.find { |m| m["type"] == "subscribed" && m["topic"] == topic }
        end
        frame || raise(Error, "subscribe to #{topic} was not confirmed")
      end

      # Every event delivered so far: the messages that carry a topic and an id.
      def events = messages.select { |m| m.key?("id") && m.key?("topic") }

      # Reads until an event satisfies the block.
      #
      # @return [Hash] the event
      def await(timeout: 30, &match)
        found = nil
        pump(timeout) { found = events.find(&match) }
        found || raise(Error, "no matching event within #{timeout}s")
      end

      # Reads for a fixed time, for a caller asserting what did NOT arrive.
      #
      # @return [Array<Hash>] every event delivered so far
      def listen(seconds)
        pump(seconds) { false }
        events
      end

      def close
        @io.close
      rescue StandardError
        nil
      end

      private

      def messages = @frames.filter_map { |f| f["message"] }

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

      # TLS decrypts ahead of the socket, so readable bytes may already be in hand.
      def buffered? = @io.is_a?(OpenSSL::SSL::SSLSocket) && @io.pending.positive?
    end
  end
end
