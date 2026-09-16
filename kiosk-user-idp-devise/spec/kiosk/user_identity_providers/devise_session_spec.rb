# frozen_string_literal: true

require "socket"

require "kiosk/user_identity_providers/devise_session"

# THE CLIENT HALF, DRIVEN OVER A REAL SOCKET.
#
# This file's subject says of itself that "nothing in it is a test double: it
# drives the shipped Devise routes over real HTTP exactly as a browser does",
# so a spec built out of stubbed `Net::HTTP` objects would assert the opposite
# of the claim it is checking. The server below is a real `TCPServer` on
# loopback speaking real HTTP/1.1; what is faked is the Devise APPLICATION, not
# the transport, and the client under test is unmodified.
#
# It exists because K-1703 found `#sign_out!` — four lines of live HTTP —
# reached by no caller and no test in the whole tree, in a gem whose client
# half shipped no spec file at all, and because K-1701's census found
# `SignInError` raised by this file and asserted by nothing.
class StubDeviseApp
  Recorded = Struct.new(:verb, :path, :headers, :body)

  attr_reader :requests

  # @param responder [Proc] called with a {Recorded}; returns
  #   `[status, [extra header lines], body]`.
  def initialize(&responder)
    @socket    = TCPServer.new("127.0.0.1", 0)
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
    verb, path = connection.gets.to_s.split
    headers = {}
    while (line = connection.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.to_s.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    body   = length.positive? ? connection.read(length) : nil

    recorded = Recorded.new(verb, path, headers, body)
    @requests << recorded

    status, extra, payload = @responder.call(recorded)
    payload = payload.to_s
    connection.write(
      +"HTTP/1.1 #{status} STATUS\r\n" +
      Array(extra).map { |header| "#{header}\r\n" }.join +
      "Content-Type: text/html\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}",
    )
  ensure
    connection&.close
  end
end

RSpec.describe Kiosk::UserIdentityProviders::DeviseSession do
  SIGN_IN_FORM = <<~HTML
    <form action="/users/sign_in" method="post">
      <input type="hidden" name="authenticity_token" value="tok-42" />
    </form>
  HTML

  let!(:app) { StubDeviseApp.new(&responder) }
  let(:session) { described_class.new(app.url) }

  after { app.stop }

  describe "#sign_in!" do
    context "when Devise takes the credentials" do
      let(:responder) do
        lambda do |request|
          if request.verb == "GET"
            [200, ["Set-Cookie: _demo_session=first; path=/"], SIGN_IN_FORM]
          else
            [302, ["Location: /", "Set-Cookie: _demo_session=rotated; path=/"], ""]
          end
        end
      end

      it "drives the real form, carries the CSRF token and keeps the rotated cookie" do
        expect(session.sign_in!(email: "alice@example.com", password: "s3cret")).to be(session)

        form, post = app.requests
        expect([form.verb, form.path]).to eq(["GET", "/users/sign_in"])
        expect([post.verb, post.path]).to eq(["POST", "/users/sign_in"])
        expect(post.body).to include("authenticity_token=tok-42")
        expect(post.body).to include("alice%40example.com")
        # The jar the form handed out goes back up with the POST...
        expect(post.headers["cookie"]).to include("_demo_session=first")
        # ...and Rails rotates it on sign-in, which a jar that only read the
        # form response would miss.
        expect(session.cookies).to eq("_demo_session" => "rotated")
      end
    end

    context "when the sign-in page does not render" do
      let(:responder) { ->(_request) { [500, [], "boom"] } }

      it "raises SignInError naming the status" do
        expect { session.sign_in!(email: "alice@example.com", password: "s3cret") }
          .to raise_error(described_class::SignInError, "sign-in form: 500")
      end
    end

    context "when Devise re-renders the form" do
      # A REJECTED sign-in answers 200 with the form again, not an error status.
      # That is the whole reason the check is on the status rather than on a
      # 2xx/5xx split, so it is the case worth its own example.
      let(:responder) do
        lambda do |request|
          request.verb == "GET" ? [200, [], SIGN_IN_FORM] : [200, [], SIGN_IN_FORM]
        end
      end

      it "raises SignInError rather than reporting a signed-in session" do
        expect { session.sign_in!(email: "alice@example.com", password: "wrong") }
          .to raise_error(described_class::SignInError, "sign-in failed: 200")
      end
    end
  end

  describe "#sign_out!" do
    let(:responder) do
      lambda do |request|
        if request.verb == "GET"
          [200, ["Set-Cookie: _demo_session=first; path=/"], SIGN_IN_FORM]
        elsif request.verb == "POST"
          [302, ["Location: /"], ""]
        else
          [303, ["Location: /", "Set-Cookie: _demo_session=; path=/"], ""]
        end
      end
    end

    it "sends Devise's DELETE with the human's jar attached" do
      session.sign_in!(email: "alice@example.com", password: "s3cret")

      response = session.sign_out!

      expect(response.code).to eq("303")
      delete = app.requests.last
      expect([delete.verb, delete.path]).to eq(["DELETE", "/users/sign_out"])
      expect(delete.headers["cookie"]).to include("_demo_session=first")
    end

    it "sends no Cookie header when the jar is empty" do
      # CONTROL: the header above is the jar's doing, not something every
      # request carries — an assertion that cannot distinguish the two would
      # pass on a client that never attached a cookie at all.
      session.sign_out!

      expect(app.requests.last.headers).not_to have_key("cookie")
    end
  end
end
