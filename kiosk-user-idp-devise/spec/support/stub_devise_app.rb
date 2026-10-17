# frozen_string_literal: true

require 'socket'

# A real TCPServer on loopback that speaks HTTP/1.1. It fakes the Devise
# application, not the transport, so the client under test is unmodified.
class StubDeviseApp
  Recorded = Struct.new(:verb, :path, :headers, :body)

  attr_reader :requests

  # @param responder [Proc] called with a {Recorded}; returns
  #   `[status, [extra header lines], body]`.
  def initialize(&responder)
    @socket    = TCPServer.new('127.0.0.1', 0)
    @responder = responder
    @requests  = []
    @thread    = Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{@socket.addr[1]}"

  def stop
    @socket.close
  rescue IOError
    nil
  ensure
    @thread&.kill
  end

  private

  def serve
    loop { handle(@socket.accept) }
  rescue IOError, Errno::EBADF, Errno::ECONNABORTED
    nil
  end

  def handle(connection)
    recorded = read_request(connection)
    @requests << recorded
    write_response(connection, *@responder.call(recorded))
  ensure
    connection&.close
  end

  def read_request(connection)
    verb, path = connection.gets.to_s.split
    headers = read_headers(connection)
    length  = headers['content-length'].to_i
    Recorded.new(verb, path, headers, length.positive? ? connection.read(length) : nil)
  end

  def read_headers(connection)
    headers = {}
    while (line = connection.gets) && line != "\r\n"
      name, value = line.split(':', 2)
      headers[name.to_s.downcase] = value.to_s.strip
    end
    headers
  end

  def write_response(connection, status, extra, payload)
    payload = payload.to_s
    connection.write(
      "HTTP/1.1 #{status} STATUS\r\n" +
      Array(extra).map { |header| "#{header}\r\n" }.join +
      "Content-Type: text/html\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}"
    )
  end
end

RSpec.shared_context 'with a stub Devise app' do
  let(:sign_in_form) do
    <<~HTML
      <form action="/users/sign_in" method="post">
        <input type="hidden" name="authenticity_token" value="tok-42" />
      </form>
    HTML
  end

  let!(:app) { StubDeviseApp.new(&responder) }
  let(:session) { described_class.new(app.url) }

  after { app.stop }
end
