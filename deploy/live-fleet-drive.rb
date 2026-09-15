#!/usr/bin/env ruby
# frozen_string_literal: true

# Drive the DEPLOYED fleet with the code this repository ships.
#
# WHAT IT IS. A hand-run, deploy-time probe. It takes every vhost out of
# deploy/Caddyfile, dials it over https with `Kiosk::Redteam::Wire` and
# `Kiosk::Redteam::Client` — the same two drivers a demo's own battery uses —
# and then runs `e2e/schema_conformance.rb` against the bytes each origin
# served. That last step is the only way §16.3's "every wire object validates
# against its JSON Schema" is ever asserted about a byte a DEPLOYMENT produced
# rather than a byte a throwaway localhost app produced.
#
# IT IS NOT A CI JOB AND MUST NOT BECOME ONE. Same reason
# deploy/check-live-hsts.sh and bin/check-live-skill-pin are not: it compares
# the LIVE fleet against the WORKING TREE, and those two are supposed to differ
# between a commit and a deploy. A gate that reddens on a box this repository
# does not deploy is a gate that gets switched off.
#
# EVERY PROBE HERE IS READ-ONLY, and that is a hard constraint rather than a
# style. A fleet member is somebody's running deployment; this script may look
# at it and may not change it. So it registers nothing, pays nothing, binds
# nothing and deletes nothing:
#
#   * the two REGISTRATION probes are the ones that must be REFUSED — an
#     unproven registration and a malformed proof. Neither creates an agent,
#     because the toll is settled before the possession proof is even read.
#   * the query probes carry a forged bearer or no bearer at all, so the
#     answer is a refusal and no row is read, let alone written.
#
# WHAT IT THEREFORE CANNOT RUN, named rather than left as a silence: every
# shipped `Kiosk::Redteam::Scenarios::*` except the registration pair, because
# each of them registers its own principals and stages the state its attack
# needs — CrossTenantRead needs two tenants and a row, MandateReplay needs a
# settled payment, ExpiredKyc needs an attested agent. Even
# RegistrationWithoutPow is only half-run: its CONTROL solves a real Equihash
# proof and registers successfully, which is a write. Running the full battery
# against the fleet needs a box we own and `deploy/demo-reset.sh` afterwards,
# and that is a different tool from this one.
#
# USAGE
#   deploy/live-fleet-drive.rb                  # every vhost in deploy/Caddyfile
#   deploy/live-fleet-drive.rb HOST [HOST...]   # only these
#   deploy/live-fleet-drive.rb --self-test      # fixtures + a vacuity arm, no network
#
# It needs a bundle carrying kiosk-redteam, kiosk-server and json_schemer. Any
# demo's bundle has all three, so it re-execs itself under one rather than
# asking you to remember which directory to stand in. KIOSK_DRIVE_BUNDLE names
# a different demo if you want a specific one.

REPO = File.expand_path("..", __dir__)

# ── Bundle: re-exec under a demo's Gemfile when this process cannot load the
#    drivers. Guarded so a bundle that still cannot load them fails LOUDLY
#    instead of re-execing forever.
begin
  require "kiosk/redteam"
rescue LoadError => e
  abort "live-fleet-drive: #{e.message}\n  …and re-exec already happened, so the " \
        "bundle named by KIOSK_DRIVE_BUNDLE does not carry kiosk-redteam." if ENV["KIOSK_DRIVE_REEXEC"]

  demo = ENV["KIOSK_DRIVE_BUNDLE"] ||
         Dir[File.join(REPO, "kiosk-demo-*")].sort.find { |d| File.exist?(File.join(d, "Gemfile.lock")) }
  abort "live-fleet-drive: no demo bundle to borrow — run `bundle install` in a kiosk-demo-* first" unless demo

  demo = File.join(REPO, demo) unless demo.start_with?("/")
  exec({ "BUNDLE_GEMFILE" => File.join(demo, "Gemfile"), "KIOSK_DRIVE_REEXEC" => "1" },
       "bundle", "exec", "ruby", __FILE__, *ARGV)
end

require "json"

CADDYFILE = File.join(REPO, "deploy", "Caddyfile")
CONFORMANCE = File.join(REPO, "e2e", "schema_conformance.rb")

# Leak vocabulary for the refusals below: a problem document may name the code
# and the title, and must never hand a stranger the runtime's internals.
LEAK_NEEDLES = ["PG::", "ActiveRecord::", "22P02", "invalid input syntax",
                "/app/", "gems/", "SELECT ", "structure.sql"].freeze

# ── The hosts, DERIVED from deploy/Caddyfile's own vhost blocks ──────────────
#
# Same rule deploy/check-live-hsts.sh uses, and for the same reason: a demo
# added to the fleet must not be invisible to this because someone forgot a
# second list.
def hosts_from_caddyfile(path = CADDYFILE)
  return [] unless File.readable?(path)

  File.readlines(path)
      .map { |line| line.sub(/#.*\z/, "") }
      .grep(/\A[a-z0-9.-]+\.[a-z]+\s*\{\s*\z/)
      .map { |line| line.sub(/\s*\{\s*\z/, "").strip }
      .uniq
end

# ── One origin's verdict ────────────────────────────────────────────────────
Finding = Struct.new(:origin, :beat, :detail)

class Drive
  attr_reader :breaches, :errors, :passes, :skips

  def initialize(origin)
    @origin   = origin
    @wire     = Kiosk::Redteam::Wire.new(base_url: origin)
    @client   = Kiosk::Redteam::Client.new(base_url: origin)
    @breaches = []
    @errors   = []
    @passes   = 0
    @skips    = []
  end

  def ok(beat)
    @passes += 1
    puts "  \e[1;32m✓\e[0m #{beat}"
  end

  def breach(beat, detail)
    @breaches << Finding.new(@origin, beat, detail)
    puts "  \e[1;31m✗ BREACH\e[0m #{beat}\n      #{detail}"
  end

  def error(beat, detail)
    @errors << Finding.new(@origin, beat, detail)
    puts "  \e[1;31m✗\e[0m #{beat}\n      #{detail}"
  end

  def skip(beat, reason)
    @skips << beat
    puts "  \e[1;33m–\e[0m SKIP #{beat} (#{reason})"
  end

  # Discovery + catalog. Also the gate on everything below: an origin that
  # serves no discovery document is not a Kiosk origin and the wire probes
  # would be asserting about somebody else's 404s.
  # @return [Hash, nil] the served catalog, or nil when this is not a Kiosk origin
  def survey
    raw = @wire.get("/.well-known/kiosk.json")
    if raw.status == 404
      skip "the whole wire battery", "serves no discovery document — not a Kiosk origin"
      return nil
    end
    unless raw.status == 200 && raw.body.is_a?(Hash) && raw.body["kiosk"]
      error "GET /.well-known/kiosk.json", "HTTP #{raw.status} #{raw.raw_body[0, 200].inspect}"
      return nil
    end
    ok "discovery document served (endpoint #{raw.body.dig("kiosk", "endpoint")})"

    catalog = @wire.get("/kiosk/schema")
    unless catalog.status == 200 && catalog.body.is_a?(Hash)
      error "GET /kiosk/schema", "HTTP #{catalog.status}"
      return nil
    end
    ok "catalog served (#{Array(catalog.body["queries"]).size} queries, " \
       "#{Array(catalog.body["actions"]).size} actions)"
    catalog.body
  end

  # An unproven registration and a malformed proof must both be REFUSED. A 201
  # to either is a real breach AND the only way this script could create state,
  # so it is reported rather than retried.
  #
  # THE ADMITTED SET IS WIDER THAN `Kiosk::Redteam.blocked?` ALLOWS, on purpose.
  # That predicate excludes 400 because a validation error is not evidence of an
  # auth gate — true of an attack on a VERB, and not the question here. The
  # claim is that an unpaid caller does not get an agent: `pow: :skip` is met by
  # the toll (402 pow_required) and `pow: "0"` is met by the header parser (400
  # bad_request), and both are the registration being refused before any
  # possession proof is read. What would be a finding is a 201, or a 5xx, or a
  # 2xx of any other shape.
  REFUSALS = [400, 401, 402, 403].freeze

  def registration_probes
    { "an unproven registration" => :skip, "a malformed proof" => "0" }.each do |beat, pow|
      response = @client.register_raw(name: "live-fleet-drive", pow: pow)
      if response.status == 201
        breach beat, "HTTP 201 — the origin MINTED AN AGENT for a caller that proved nothing. " \
                     "This also means this run created state; deploy/demo-reset.sh clears it."
      elsif REFUSALS.include?(response.status)
        ok "#{beat} is refused (HTTP #{response.status} " \
           "#{Kiosk::Redteam.error_code(response).inspect})"
      else
        error beat, "HTTP #{response.status} #{response.body.inspect} — neither a refusal nor a " \
                    "success, so nothing was proved about the gate"
      end
      leak_check(beat, response.body)
    end
  end

  # A forged bearer, no bearer at all, the wrong method at a real verb's path,
  # and a verb nobody registered. All four are refusals by construction, so all
  # four are reads that read nothing.
  def wire_probes(catalog)
    query = Array(catalog["queries"]).first&.fetch("name", nil)
    return skip "the query-plane probes", "this origin publishes no query" unless query

    forged = @wire.get("/kiosk/#{query}", {}, Kiosk::Redteam::Wire.bearer("not.a.token"))
    judge "a forged bearer at /kiosk/#{query}", forged, [401, 403]

    anon = @wire.get("/kiosk/#{query}")
    judge "no bearer at all at /kiosk/#{query}", anon, [401, 403]

    # METHOD MISMATCH. An origin draws ONE EXPLICIT ROUTE PER VERB with the
    # method following the kind — GET for a query, POST for an action — so a
    # POST at a query's path matches no route at all and the answer is the host
    # framework's ordinary 404: an HTML page with no `Allow` and no
    # problem-document `code`. That is the engine's stated design, not a gap,
    # and it is the same assertion each demo's own `MethodMismatch` beat makes.
    # The security half is what is being checked: the wrong method must never
    # reach the verb, and a 200 here would mean it did.
    mismatch = @wire.request(:post, "/kiosk/#{query}")
    if mismatch.status == 404 && mismatch["allow"].nil? &&
       !(mismatch.body.is_a?(Hash) && mismatch.body["code"])
      ok "POST at a query's path is a plain 404 — no Allow, no code, the verb not reached"
    else
      breach "POST at /kiosk/#{query} (method mismatch)",
             "HTTP #{mismatch.status} Allow=#{mismatch["allow"].inspect} " \
             "code=#{mismatch.body.is_a?(Hash) ? mismatch.body["code"].inspect : "—"}"
    end

    # A name nobody registered is the same ordinary 404, for the same reason.
    unknown = @wire.get("/kiosk/no_such_verb_#{Time.now.to_i}")
    if unknown.status == 404 && !(unknown.body.is_a?(Hash) && unknown.body["code"])
      ok "an unregistered verb name is a plain 404 with no problem-document code"
    else
      breach "an unregistered verb name",
             "HTTP #{unknown.status} #{unknown.raw_body[0, 200].inspect}"
    end
  end

  def judge(beat, raw, admitted)
    if admitted.include?(raw.status)
      ok "#{beat} is refused (HTTP #{raw.status} #{raw.body.is_a?(Hash) ? raw.body["code"].inspect : "—"})"
    elsif raw.status.zero?
      error beat, "the connection failed: #{raw.body.inspect}"
    elsif raw.status >= 500
      breach beat, "HTTP #{raw.status} — a crash is not a refusal"
    else
      breach beat, "HTTP #{raw.status} #{raw.raw_body[0, 200].inspect} — expected one of #{admitted.inspect}"
    end
    leak_check(beat, raw.respond_to?(:raw_body) ? raw.raw_body : raw.body)
  end

  def leak_check(beat, body)
    scan = Kiosk::Redteam::LeakScan.scan(body, LEAK_NEEDLES)
    breach "#{beat} — leak scan", "the refusal body names #{scan.leak.inspect}" if scan.leak?
  end

  # The published JSON Schemas against THIS origin's served bytes.
  def schema_conformance
    env = { "SERVER_URL" => @origin, "KIOSK_LIVE" => "1" }
    if system(env, RbConfig.ruby, CONFORMANCE)
      @passes += 1
    else
      @errors << Finding.new(@origin, "schema_conformance.rb", "exited non-zero — see above")
    end
  end
end

def drive(origin)
  puts
  puts "\e[1m── #{origin} ──\e[0m"
  run = Drive.new(origin)
  catalog = run.survey
  if catalog
    run.registration_probes
    run.wire_probes(catalog)
    run.schema_conformance
  end
  run
end

def self_test
  failures = []
  check = lambda do |name, ok|
    puts(ok ? "  ok   #{name}" : "  FAIL #{name}")
    failures << name unless ok
  end

  require "tmpdir"
  Dir.mktmpdir("live-fleet-selftest") do |dir|
    path = File.join(dir, "Caddyfile")
    File.write(path, <<~CADDY)
      # a comment naming fake.example.com { which must not be read as a vhost
      (shared) {
        header Strict-Transport-Security "max-age=31536000; includeSubDomains"
      }

      one.demo.kiosk.tech {
        reverse_proxy localhost:3001
      }
      two.demo.kiosk.tech {
        reverse_proxy localhost:3002
      }
    CADDY
    hosts = hosts_from_caddyfile(path)
    check.call("derives every vhost", hosts == %w[one.demo.kiosk.tech two.demo.kiosk.tech])
    check.call("does not read a commented host as a vhost", hosts.none? { _1.include?("fake") })
    check.call("does not read a named snippet as a vhost", hosts.none? { _1.include?("shared") })
    check.call("an unreadable Caddyfile answers empty", hosts_from_caddyfile(File.join(dir, "nope")).empty?)
  end

  # THE PRECONDITION OF THE WHOLE SCRIPT: the drivers it is built on must dial
  # TLS from the target's scheme. A fleet is served over https, so a driver that
  # cannot is a runner that reaches nothing — and it fails by CONNECTION RESET,
  # which reads like the box being down rather than like a bug here.
  https = Kiosk::Redteam::Wire.http_for(URI("https://one.demo.kiosk.tech/kiosk/schema"))
  plain = Kiosk::Redteam::Wire.http_for(URI("http://127.0.0.1:3001/kiosk/schema"))
  check.call("the drivers this script uses dial TLS for an https origin", https.use_ssl?)
  check.call("…and do not for a local http one", !plain.use_ssl?)

  # VACUITY: the real Caddyfile must still yield a fleet, and the harness this
  # script hands the served bytes to must still exist.
  check.call("the tracked Caddyfile yields at least one vhost", hosts_from_caddyfile.any?)
  check.call("e2e/schema_conformance.rb is where this expects it", File.exist?(CONFORMANCE))
  check.call("…and it carries the live-mode switch",
             File.read(CONFORMANCE).include?('LIVE = ENV["KIOSK_LIVE"] == "1"'))

  if failures.empty?
    puts "SELF-TEST OK"
    0
  else
    puts "SELF-TEST FAILED: #{failures.size} arm(s)"
    1
  end
end

exit self_test if ARGV.include?("--self-test")

require "uri"
hosts = ARGV.empty? ? hosts_from_caddyfile : ARGV
if hosts.empty?
  abort "live-fleet-drive: no hosts. The list is derived from deploy/Caddyfile's vhost blocks; " \
        "an empty list means the derivation stopped matching, not that the fleet is fine."
end

runs = hosts.map { |host| drive(host.start_with?("http") ? host : "https://#{host}") }

puts
puts "\e[1m── the fleet ──\e[0m"
breaches = runs.flat_map(&:breaches)
errors   = runs.flat_map(&:errors)
puts "  #{hosts.size} origin(s) · #{runs.sum(&:passes)} passed · " \
     "#{breaches.size} breach(es) · #{errors.size} error(s) · " \
     "#{runs.sum { _1.skips.size }} skipped"
puts "  NOTHING WAS WRITTEN: every probe above is a read or a refusal."
(breaches + errors).each { |f| puts "  #{f.origin}  #{f.beat} — #{f.detail}" }

exit((breaches + errors).empty? ? 0 : 1)
