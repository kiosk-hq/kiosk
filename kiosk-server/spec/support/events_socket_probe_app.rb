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
# declares the topics the scenarios need, installs a fake agent-IdP that accepts
# one bearer token, serves the app on an ephemeral port, then drives the
# scenarios below over a REAL WebSocket and prints one JSON report on stdout.
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
require "stringio"

REPORT = {}
# The engine's own log, so a scenario can assert a line the wire cannot carry.
# ERROR level only: everything below it is request noise.
LOG = StringIO.new

# ── a fake agent-IdP: one token, one identity ────────────────────────────────
GOOD_TOKEN = "good-token"
REVOKED    = { value: false }
# The operator's answer to "may this subscriber read this subject", flipped
# under a socket that is already holding one.
REACHABLE  = { value: true }
# The `exp` this IdP stamps on the identity it resolves, and after which it
# stops resolving at all. Moved back under a held socket to age its token out.
EXPIRES_AT = { value: Time.now.to_i + 3600 }

class ProbeIdp
  def verify(request)
    header = request.headers["Authorization"] || request.headers["HTTP_AUTHORIZATION"]
    return nil unless header.to_s == "Bearer #{GOOD_TOKEN}"
    return nil if REVOKED[:value]
    return nil if Time.now.to_i >= EXPIRES_AT[:value]

    Kiosk::Identity.new(user_id: "u1", role: "customer", actor: "agent", agent_id: "a1",
                        claims: { exp: EXPIRES_AT[:value] })
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
    subject_reachable ->(subject, _identity) { REACHABLE[:value] && subject.to_s == "list_ok" }
  end

  topic :boom do
    reach :consented
    description "A topic whose own subject rule raises."
    payload_schema type: "object"
    subject_reachable ->(_subject, _identity) { raise "operator rule blew up" }
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
  config.logger = Logger.new(LOG, level: Logger::ERROR)
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

# The shipped re-authorisation period is thirty seconds. Shortened to one so a
# scenario that waits for a tick finishes inside the suite; the registration
# itself — `periodically :reauthorise!` — is the shipped one, untouched.
KioskEvents.periodic_timers =
  KioskEvents.periodic_timers.map { |callback, options| [callback, options.merge(every: 1)] }

ProbeApp.initialize!
ProbeApp.routes.draw do
  mount Kiosk::Server::Engine => "/kiosk"
  get "/kiosk/list_nothing", to: "probe#list_nothing", defaults: { kiosk_verb: "list_nothing" }
end

# ── the client ───────────────────────────────────────────────────────────────
class ProbeSocket
  attr_reader :frames

  def initialize(port, path, headers)
    @url = "ws://127.0.0.1:#{port}#{path}"
    @tcp = TCPSocket.new("127.0.0.1", port)
    @frames = []
    @open = false
    @closed = false
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
  # Everything the refused socket is told before it goes, which is the typed
  # disconnect spec Section 8.5.3 names and nothing else.
  sock.pump_until(seconds: 2) { sock.closed? }
  REPORT[:no_auth_frames] = sock.frames
  sock.close

  # 2 — a bad token: refused.
  sock = connect(port, headers: { "Origin" => Kiosk.configuration.issuer,
                                  "Authorization" => "Bearer nope" })
  sock.pump_until(seconds: 2) { sock.frames.any? || sock.closed? }
  REPORT[:bad_token_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 2b — a GOOD token, but in the query string: refused. Spec Section 8.5.3
  # forbids an operator to accept the access token anywhere but the
  # `Authorization` header, and the engine reads it nowhere else.
  sock = connect(port, headers: { "Origin" => Kiosk.configuration.issuer },
                       path: "/kiosk/events?access_token=#{GOOD_TOKEN}")
  sock.pump_until(seconds: 2) { sock.frames.any? || sock.closed? }
  REPORT[:query_token_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
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
  # The FRAME the confirmation travels in, rather than the message inside it:
  # everything about one subscription is wrapped, and everything about the
  # connection is not (spec Section 8.5.4).
  REPORT[:subscribed_envelope] =
    sock.frames.find { |f| f.dig("message", "type") == "subscribed" }
  sock.pump_until { sock.frames.any? { |f| f["type"] == "confirm_subscription" } }
  REPORT[:confirmation] = sock.frames.find { |f| f["type"] == "confirm_subscription" }

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

  # 13 — NO `Origin` header at all, and the upgrade is accepted. The
  #      `Authorization` header is the authorisation; `Origin` is a browser's
  #      forgery control and there is no browser on this exchange.
  sock = connect(port, headers: { "Authorization" => "Bearer #{GOOD_TOKEN}" })
  sock.pump_until { sock.frames.any? }
  REPORT[:no_origin_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 14 — an `Origin` naming somewhere else entirely, same answer: a browser
  #      cannot attach the `Authorization` header cross-origin, so the header
  #      that decides this upgrade is one an attacker's page cannot send.
  sock = connect(port, headers: { "Origin" => "https://example.com",
                                  "Authorization" => "Bearer #{GOOD_TOKEN}" })
  sock.pump_until { sock.frames.any? }
  REPORT[:foreign_origin_welcomed] = sock.frames.any? { |f| f["type"] == "welcome" }
  sock.close

  # 15 — an operator's OWN subject rule raises. The refusal is right, because
  #      the safe reading of a broken authorisation rule is NO — and the
  #      operator whose lambda raised has to be able to find out, which the
  #      wire cannot tell them.
  sock = connect(port)
  sock.pump_until { sock.frames.any? }
  sock.subscribe(identifier("boom", subject: "anything"))
  sock.pump_until do
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("boom") }
  end
  REPORT[:raising_rule_rejected] =
    sock.frames.any? { |f| f["type"] == "reject_subscription" && f["identifier"].include?("boom") }
  REPORT[:raising_rule_logged] =
    LOG.string.include?(%([kiosk] events subject rule raised for topic "boom": RuntimeError: operator rule blew up))
  sock.close

  # ── re-authorisation while the subscription stands (spec Section 8.5.6) ───
  #
  # Two sockets are opened and HELD while the operator's answers change under
  # them. `held` carries the subject-scoped `consented` subscription, whose
  # reach is withdrawn; `plain` carries a principal one and only reacts to the
  # credential. Both run the same timer, so `plain` staying quiet through the
  # first change is what says the teardown was aimed rather than global.
  held = connect(port, path: "/kiosk/events?topic=todo:list_ok")
  held.pump_until { held.messages.any? { |m| m["type"] == "subscribed" } }
  plain = connect(port, path: "/kiosk/events?topic=order_payment")
  plain.pump_until { plain.messages.any? { |m| m["type"] == "subscribed" } }

  # 16 — nothing has changed, so several periods later neither socket has been
  #      told anything. A timer that tore a valid subscription down would be as
  #      wrong as one that never ran.
  held.pump_until(seconds: 3) { false }
  plain.pump_until(seconds: 1) { false }
  REPORT[:steady_unsubscribed] = held.messages.any? { |m| m["type"] == "unsubscribed" }
  REPORT[:steady_disconnected] = plain.frames.any? { |f| f["type"] == "disconnect" }

  # 17 — the operator's own rule stops saying yes. Delivery stops and the
  #      client is told why, on the subscription that lost it and no other.
  REACHABLE[:value] = false
  held.pump_until(seconds: 5) { held.messages.any? { |m| m["type"] == "unsubscribed" } }
  REPORT[:reach_revoked_frame] = held.messages.find { |m| m["type"] == "unsubscribed" }
  plain.pump_until(seconds: 2) { false }
  REPORT[:other_socket_unsubscribed] = plain.messages.any? { |m| m["type"] == "unsubscribed" }

  # 18 — the credential stops resolving for a reason that is not expiry. The
  #      whole connection goes, and the client is told that coming back with
  #      this token will not help.
  REVOKED[:value] = true
  plain.pump_until(seconds: 5) { plain.frames.any? { |f| f["type"] == "disconnect" } }
  REPORT[:revoked_frame] = plain.frames.find { |f| f["type"] == "disconnect" }
  plain.pump_until(seconds: 3) { plain.closed? }
  REPORT[:revoked_socket_closed] = plain.closed?
  held.close
  plain.close

  # 19 — the access token AGES OUT under a held socket. The two sockets differ
  #      in nothing but their credential's `exp`, and that is what separates
  #      "come back" from "stop". Last, because after it no upgrade resolves.
  REVOKED[:value] = false
  EXPIRES_AT[:value] = Time.now.to_i + 3
  expiring = connect(port, path: "/kiosk/events?topic=order_payment")
  expiring.pump_until { expiring.messages.any? { |m| m["type"] == "subscribed" } }
  expiring.pump_until(seconds: 8) { expiring.frames.any? { |f| f["type"] == "disconnect" } }
  REPORT[:expired_frame] = expiring.frames.find { |f| f["type"] == "disconnect" }
  expiring.close

  REPORT[:ok] = true
rescue StandardError => e
  REPORT[:error] = "#{e.class}: #{e.message}"
  REPORT[:backtrace] = e.backtrace&.first(6)
end

puts JSON.generate(REPORT)
exit 0
