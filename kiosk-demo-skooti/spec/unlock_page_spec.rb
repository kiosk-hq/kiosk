# frozen_string_literal: true

# The /unlock page: the URL a rental verb answers as `unlock_url`.
#
#   bundle exec rails runner spec/unlock_page_spec.rb
#
# `rake check:rideflow` runs it first. It drives the page through the full
# Rack stack in-process and asserts that it shows what the URL carries — the
# QR of that same URL, the token and the vehicle — reads nothing from the
# database, and keeps the token out of logs, caches and referrers.

FAILURES = []

def assert(cond, msg)
  if cond
    puts "  OK  #{msg}"
  else
    FAILURES << msg
    puts "  FAIL  #{msg}"
  end
end

session = ActionDispatch::Integration::Session.new(Rails.application)
session.host = "127.0.0.1"
# Each request on its own thread: the runner's executor context is this
# thread's, and a request served on it would unwind that context underneath it.
get = ->(path) { Thread.new { session.get(path) }.value }

token = "skooti-rt-v1|SK-001|0f8c1d2e-6b1e-4a52-9f5e-1d2c3b4a5f60|1700000000|1700000900|jti-1.c2lnbmF0dXJl"
url   = UnlockLink.url(origin: "http://127.0.0.1", scooter_code: "SK-001", rental_token: token)

puts "\n── /unlock shows what its URL carries ──"

get.(UnlockLink::PATH) # the first request runs development's pending-migration check
queries = []
counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
status = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get.(url) }
body   = session.response.body

assert(status == 200, "GET #{UnlockLink::PATH} with scooter and rt → 200 (got #{status})")
assert(body.include?(UnlockLink.svg(url)), "the page renders the QR of its own URL")
assert(body.include?(token), "the page shows the token verbatim")
assert(body.include?("SK-001"), "the page names the vehicle")
assert(queries.empty?, "the page reads nothing from the database (#{queries.inspect})")
assert(session.response.headers["Cache-Control"].to_s.include?("no-store"), "Cache-Control: no-store")
assert(session.response.headers["Referrer-Policy"] == "no-referrer", "Referrer-Policy: no-referrer")

filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
assert(filter.filter("rt" => token)["rt"] == "[FILTERED]", "`rt` is filtered from the request log")
assert(filter.filter("cart" => "x")["cart"] == "x", "the `rt` filter matches the key exactly")

puts "\n── a URL missing either half is refused ──"
{
  "no rt"          => "#{UnlockLink::PATH}?scooter=SK-001",
  "no scooter"     => "#{UnlockLink::PATH}?rt=#{CGI.escape(token)}",
  "rt as an array" => "#{UnlockLink::PATH}?scooter=SK-001&rt[]=x",
}.each do |label, path|
  code = get.(path)
  assert(code == 400, "#{label} → 400 (got #{code})")
end

if FAILURES.empty?
  puts "\nunlock-page spec: ALL PASS"
  exit 0
else
  puts "\nunlock-page spec: #{FAILURES.size} FAILURE(S)"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
