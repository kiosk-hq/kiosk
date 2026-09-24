# frozen_string_literal: true

# The socket probe behind spec/kiosk/server/events_socket_spec.rb — run as a
# SUBPROCESS, never loaded into the RSpec process.
#
# Out-of-process for the reason engine_mount_probe_app.rb gives (booting Rails
# inside the suite mutates it globally) and for one more of its own: this boots
# PUMA and holds real TCP sockets, and a server thread that outlives an example
# is a flake in every example after it.
#
# It boots a Rails application with kiosk-server loaded and the engine mounted,
# declares one topic of each reach, installs a fake agent-IdP that accepts one
# bearer token, serves the app on an ephemeral port, then drives the scenarios
# below over a REAL WebSocket and prints one JSON report on stdout.
#
# The client is built on `websocket-driver`, which Action Cable already depends
# on — so the suite gains no dependency and no interpreter but Ruby.

require "bundler/setup"
require "json"
require "socket"
require "kiosk/server"
require "puma"
require "puma/configuration"
require "puma/launcher"
require "websocket/driver"
require "openssl"

REPORT = {}

# ── a fake agent-IdP: one token, one identity ────────────────────────────────
GOOD_TOKEN = "good-token"
REVOKED    = { value: false }

class ProbeIdp
  def verify(request)
    header = request.headers["Authorization"] || request.headers["HTTP_AUTHORIZATION"]
    return nil unless header.to_s == "Bearer #{GOOD_TOKEN}"
    return nil if REVOKED[:value]

    Kiosk::Identity.new(user_id: "u1", role: "customer", actor: "agent", agent_id: "a1")
  end
end

class ProbeController < ActionController::Base
  include Kiosk::Handler

  topic :order_payment do
    description "Your order was paid."
    payload_schema type: "object"
  end

  topic :todo do
    reach :consented
    description "A todo on a list you can reach changed."
    payload_schema type: "object"
    subject_reachable ->(subject, _identity) { subject.to_s == "list_ok" }
  end

  kind :query
  description "Lists nothing, so the origin has a verb and a catalogue."
  input_schema type: "object", additionalProperties: false, properties: {}
  output_schema type: "array", items: { type: "object" }
  def list_nothing
    render json: []
  end
end

class ProbeApp < Rails::Application
  config.eager_load = false
  config.hosts.clear
  config.logger = Logger.new(IO::NULL)
  config.secret_key_base = "x" * 64
end

Kiosk.configure do |c|
  c.issuer    = "http://127.0.0.1:#{ENV.fetch("PROBE_PORT")}"
  c.handlers  = ["ProbeController"]
  c.agent_idp = ProbeIdp.new
  # A real key, generated here: the engine crashes rather than inventing one
  # outside development, which is the posture we want and the reason a fixture
  # booted in production has to bring its own.
  c.signing_key = Kiosk::Server::SigningKey.from_pem(OpenSSL::PKey::RSA.new(2048).to_pem)
end

ProbeApp.initialize!
ProbeApp.routes.draw do
  mount Kiosk::Server::Engine => "/kiosk"
  get "/kiosk/list_nothing", to: "probe#list_nothing", defaults: { kiosk_verb: "list_nothing" }
end

# ── the client ───────────────────────────────────────────────────────────────
class ProbeSocket
  attr_reader :frames, :handshake_status

  def initialize(port, path, headers)
    @url = "ws://127.0.0.1:#{port}#{path}"
    @tcp = TCPSocket.new("127.0.0.1", port)
    @frames = []
    @open = false
    @closed = false
    @handshake_status = nil
    @driver = WebSocket::Driver.client(self)
    headers.each { |k, v| @driver.set_header(k, v) }
    @driver.on(:open)    { @open = true }
    @driver.on(:message) { |e| @frames << JSON.parse(e.data) }
    @driver.on(:close)   { @closed = true }
    @driver.on(:error)   { @closed = true }
    @driver.start
  end

  def url = @url
  def write(data) = @tcp.write(data)

  # Pump until the block is satisfied or the deadline passes. Returns whether
  # it was satisfied, so every assertion below is a fact about what ARRIVED
  # rather than about how long we happened to wait.
  def pump_until(seconds: 4)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      break if @closed

      ready = IO.select([@tcp], nil, nil, 0.1)
      next unless ready

      begin
        @driver.parse(@tcp.read_nonblock(8192))
      rescue IO::WaitReadable
        next
      rescue EOFError, Errno::ECONNRESET
        @closed = true
      end
    end
    yield
  end

  def open? = @open
  def closed? = @closed

  def subscribe(identifier)
    @driver.text(JSON.generate("command" => "subscribe", "identifier" => JSON.generate(identifier)))
  end

  def messages = frames.filter_map { |f| f["message"] }

  def close
    @tcp.close
  rescue StandardError
    nil
  end
end

def identifier(topic, **rest)
  { "channel" => "KioskEvents", "topic" => topic }.merge(rest.transform_keys(&:to_s))
end

def connect(port, headers: nil, path: "/kiosk/events")
  ProbeSocket.new(port, path, headers || {
    "Origin" => Kiosk.configuration.issuer,
    "Authorization" => "Bearer #{GOOD_TOKEN}",
  })
end

# ── boot Puma ────────────────────────────────────────────────────────────────
port = ENV.fetch("PROBE_PORT").to_i
conf = Puma::Configuration.new do |user_config|
  user_config.bind "tcp://127.0.0.1:#{port}"
  user_config.app ProbeApp
  user_config.threads 2, 4
  user_config.environment "production"
end
launcher = Puma::Launcher.new(conf, events: Puma::Events.new)
Thread.new { launcher.run }

# Wait for the listener, and FAIL rather than hang if it never comes: a probe
# that blocks forever is read as a hung suite, which says nothing about the
# subject.
listening = false
40.times do
  begin
    TCPSocket.new("127.0.0.1", port).close
    listening = true
    break
  rescue Errno::ECONNREFUSED
    sleep 0.1
  end
end
unless listening
  puts JSON.generate(error: "puma never listened on #{port}")
  exit 0
end

store = Kiosk.configuration.event_store

begin
  # 1 — no Authorization: the upgrade is refused.
  sock = connect(port, headers: { "Origin" => Kiosk.configuration.issuer })
  # Action Cable completes the WebSocket handshake and THEN runs `connect`, so
  # a refused upgrade still answers 101 and is closed immediately after. The
  # fact that separates accepted from refused is therefore the `welcome` frame,
  # never the 101.
  sock.pump_until(seconds: 2) { sock.frames.any? || sock.closed? }
  REPORT[:no_auth_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 2 — a bad token: refused.
  sock = connect(port, headers: { "Origin" => Kiosk.configuration.issuer,
                                  "Authorization" => "Bearer nope" })
  sock.pump_until(seconds: 2) { sock.frames.any? || sock.closed? }
  REPORT[:bad_token_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 3 — a good upgrade: 101, and the welcome frame.
  sock = connect(port)
  sock.pump_until { sock.frames.any? }
  REPORT[:opened] = sock.open?
  REPORT[:welcome] = sock.frames.first

  # 4 — subscribe to a declared, principal-reach topic.
  sock.subscribe(identifier("order_payment"))
  sock.pump_until { sock.messages.any? { |m| m["type"] == "subscribed" } }
  REPORT[:subscribed] = sock.messages.find { |m| m["type"] == "subscribed" }

  # 5 — an UNdeclared topic is rejected, not streamed empty.
  sock.subscribe(identifier("nope"))
  sock.pump_until { sock.frames.any? { |f| f["type"] == "reject_subscription" } }
  REPORT[:undeclared_rejected] =
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("nope") }

  # 6 — a consented topic whose subject is NOT reachable is rejected.
  sock.subscribe(identifier("todo", subject: "list_no"))
  sock.pump_until do
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("list_no") }
  end
  REPORT[:unreachable_subject_rejected] =
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("list_no") }

  # 7 — and the reachable one is accepted.
  sock.subscribe(identifier("todo", subject: "list_ok"))
  sock.pump_until { sock.messages.count { |m| m["type"] == "subscribed" } >= 2 }
  REPORT[:reachable_subject_subscribed] =
    sock.messages.count { |m| m["type"] == "subscribed" } >= 2

  # 8 — LIVE delivery: emit, and the socket sees it with the five closed members.
  first_id = Kiosk::Server::Events.emit(
    topic: :order_payment, subject: "ord_1", identity_scope: %w[u1],
    data: { "status" => "paid" },
  )
  sock.pump_until { sock.messages.any? { |m| m["id"] == first_id } }
  REPORT[:live] = sock.messages.find { |m| m["id"] == first_id }

  # 9 — subject filtering: an event on another subject of a subject-scoped
  #     subscription must not arrive.
  Kiosk::Server::Events.emit(topic: :todo, subject: "list_other", identity_scope: %w[u1],
                             data: { "done" => true })
  other_id = store.head
  sock.pump_until(seconds: 1) { false }
  REPORT[:other_subject_delivered] = sock.messages.any? { |m| m["id"] == other_id }
  sock.close

  # 10 — RESUME: a second socket subscribing with `since` replays only the gap.
  gap_id = Kiosk::Server::Events.emit(
    topic: :order_payment, subject: "ord_2", identity_scope: %w[u1],
    data: { "status" => "refunded" },
  )
  resumed = connect(port)
  resumed.pump_until { resumed.frames.any? }
  resumed.subscribe(identifier("order_payment", since: first_id))
  resumed.pump_until { resumed.messages.any? { |m| m["id"] == gap_id } }
  REPORT[:resumed_ids] = resumed.messages.filter_map { |m| m["id"] }
  REPORT[:resume_head] = resumed.messages.find { |m| m["type"] == "subscribed" }
  resumed.close

  # 11 — TRUNCATED: a cursor older than what the store still holds says so.
  store.prune_before(store.head) if store.respond_to?(:prune_before)
  truncated = connect(port)
  truncated.pump_until { truncated.frames.any? }
  truncated.subscribe(identifier("order_payment", since: 0))
  truncated.pump_until { truncated.messages.any? { |m| m["type"] == "subscribed" } }
  REPORT[:truncated_frame] = truncated.messages.find { |m| m["type"] == "subscribed" }
  truncated.close

  # ── URL-declared subscriptions ────────────────────────────────────────────

  # 12 — a client that never SENDS a frame: it authenticates the upgrade the
  #      one way there is, with the header, and names its topics in the query
  #      string. Action Cable would otherwise stream it nothing at all.
  urlsub = connect(port, path: "/kiosk/events?topic=order_payment&topic=todo:list_ok")
  urlsub.pump_until { urlsub.messages.count { |m| m["type"] == "subscribed" } >= 2 }
  REPORT[:url_welcomed] = urlsub.frames.any? { |f| f["type"] == "welcome" }
  REPORT[:url_subscribed_topics] =
    urlsub.messages.select { |m| m["type"] == "subscribed" }.map { |m| m["topic"] }.sort

  # DELIBERATELY emitting on the `subscribed` frame and NOT on Action Cable's
  # later `confirm_subscription`: that window is where an event used to be lost,
  # and this is the assertion that it no longer is.
  url_id = Kiosk::Server::Events.emit(
    topic: :order_payment, subject: "ord_3", identity_scope: %w[u1], data: { "status" => "paid" },
  )
  urlsub.pump_until(seconds: 6) { urlsub.messages.any? { |m| m["id"] == url_id } }
  REPORT[:url_delivered] = urlsub.messages.any? { |m| m["id"] == url_id }

  urlsub.close

  REPORT[:ok] = true
rescue StandardError => e
  REPORT[:error] = "#{e.class}: #{e.message}"
  REPORT[:backtrace] = e.backtrace&.first(6)
end

puts JSON.generate(REPORT)
exit 0
