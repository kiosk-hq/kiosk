# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-hoteling.
# Tasks:
#
#   rake demo:setup   idempotent db:drop / create / migrate / seed
#   rake demo:book    boots the server, runs hoteling_flow.rb (no-human full
#                     booking chain), asserts happy path + negative gate
#   rake demo         setup + book (full end-to-end proof)

namespace :demo do
  desc "Create + load schema + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    structure_sql = File.expand_path("../../db/structure.sql", __dir__)
    if File.exist?(structure_sql)
      sh "bundle exec rails db:drop db:create db:schema:load db:seed"
    else
      sh "bundle exec rails db:drop db:create db:migrate db:seed"
    end
  end

  desc "Boot the server, run hoteling_flow.rb end-to-end (happy + payment-gate negative), assert."
  task :book do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"
    require "openssl"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-hoteling-demo.log"

    # ── host resolution ────────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("hoteling.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.app — using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_hoteling_development"
    flow_rb      = File.expand_path("../../hoteling_flow.rb", __dir__)

    failures = []

    # Helper: spawn the server, wait for readiness, yield, then kill.
    boot_server = lambda do |&blk|
      File.truncate(log, 0) if File.exist?(log)
      server_pid = spawn(
        { "KIOSK_ISSUER" => kiosk_issuer },
        "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
        out: log, err: log,
      )

      begin
        ready = false
        40.times do
          begin
            res = Net::HTTP.get_response(URI("#{server_url}/.well-known/kiosk.json"))
            if res.code.to_i == 200
              ready = true
              break
            end
          rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
            nil
          end
          sleep 1
        end
        abort "Server did not become ready — see #{log}" unless ready
        puts "  Server up at #{server_url}"

        blk.call
      ensure
        begin
          Process.kill("TERM", server_pid)
          Process.wait(server_pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
        puts "  Server stopped."
      end
    end

    # Helper: run hoteling_flow.rb with the given env vars; return parsed JSON result.
    run_flow = lambda do |extra_env = {}|
      env = {
        "SERVER_URL"   => server_url,
        "KIOSK_ISSUER" => kiosk_issuer,
      }.merge(extra_env)
      env_str = env.map { |k, v| "#{k}=#{v.to_s.shellescape}" }.join(" ")
      raw = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      json_line    = raw.lines.grep(/^\{/).last
      stderr_lines = raw.lines.reject { |l| l.start_with?("{") }
      puts stderr_lines.join
      puts json_line if json_line

      begin
        JSON.parse(json_line || raw)
      rescue JSON::ParserError => e
        abort "hoteling_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
      end
    end

    # ── RUN 1: Happy path ─────────────────────────────────────────────────
    puts "\n══ RUN 1: Happy path ══"
    boot_server.call do
      result = run_flow.call

      check = lambda do |label, actual, expected|
        if actual == expected
          puts "  OK  #{label} == #{expected}"
        else
          failures << "happy: #{label} expected #{expected}, got #{actual.inspect}"
          puts "  FAIL  #{label} expected #{expected}, got #{actual.inspect}"
        end
      end

      check.call("http_register",       result["http_register"],       201)
      check.call("http_properties",     result["http_properties"],     200)
      check.call("http_availability",   result["http_availability"],   200)
      check.call("http_reserve_room",   result["http_reserve_room"],   200)
      check.call("http_pay",            result["http_pay"],            200)
      check.call("http_confirm_booking", result["http_confirm_booking"], 200)
      check.call("confirm_status",      result["confirm_status"],      "confirmed")

      booking_id = result["booking_id"]
      if booking_id && !booking_id.to_s.empty?
        puts "  OK  booking_id present (#{booking_id})"
      else
        failures << "happy: booking_id missing or empty"
        puts "  FAIL  booking_id missing or empty"
      end

      # ── psql assertions ──────────────────────────────────────────────
      b_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM public.bookings WHERE status='confirmed'" 2>&1`.strip
      if b_count.to_i >= 1
        puts "  OK  bookings[status=confirmed] >= 1 (got #{b_count})"
      else
        failures << "happy: bookings[status=confirmed] expected >= 1, got #{b_count.inspect}"
        puts "  FAIL  bookings[status=confirmed] expected >= 1, got #{b_count.inspect}"
      end

      pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.settlements' 2>&1`.strip
      if pm_count.to_i >= 1
        puts "  OK  kiosk.settlements >= 1 (got #{pm_count})"
      else
        failures << "happy: kiosk.settlements expected >= 1, got #{pm_count.inspect}"
        puts "  FAIL  kiosk.settlements expected >= 1, got #{pm_count.inspect}"
      end

      resv_kiosk_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM kiosk.reservations WHERE resource_kind='room_booking'" 2>&1`.strip
      if resv_kiosk_count.to_i >= 1
        puts "  OK  kiosk.reservations[resource_kind=room_booking] >= 1 (got #{resv_kiosk_count})"
      else
        failures << "happy: kiosk.reservations[resource_kind=room_booking] expected >= 1, got #{resv_kiosk_count.inspect}"
        puts "  FAIL  kiosk.reservations[resource_kind=room_booking] expected >= 1, got #{resv_kiosk_count.inspect}"
      end
    end

    # ── RUN 2: Server-gate negative — SKIP_PAY → 403 ─────────────────────
    puts "\n══ RUN 2: Server-gate negative — SKIP_PAY → 403 ══"
    boot_server.call do
      result = run_flow.call("SKIP_PAY" => "1")

      if result["http_confirm_booking"] == 403
        puts "  OK  SKIP_PAY: http_confirm_booking == 403"
      else
        failures << "skip_pay: http_confirm_booking expected 403, got #{result["http_confirm_booking"].inspect}"
        puts "  FAIL  SKIP_PAY: expected 403, got #{result["http_confirm_booking"].inspect}"
      end
    end

    # ── final verdict ─────────────────────────────────────────────────────
    puts "\n── Assertions ──"
    if failures.empty?
      puts "  All assertions passed."
    else
      puts "  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
end

namespace :demo do
  # ── demo:isolation ──────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial cross-tenant isolation test (P4 Task 2).

    Runs demo:setup (clean DB + seed), boots the server, runs isolation_flow.rb
    with two fresh principals (A and B), and asserts all cross-tenant denial
    properties:

      Assertion 1 (ownership denial — Gate-1 isolated): B settles a payment
        mandate referencing A's booking (Gate-2 ✓) then calls confirm_booking
        on A's booking_id. Gate-1 (user_id = kiosk.current_user_id() AND
        status='reserved') finds nothing → 403. The 403 isolates Gate-1
        because Gate-2 is genuinely satisfied by B.
      Assertion 2a (exclusion): B's my_bookings does NOT contain A's booking.
      Assertion 2b (positive control): B's my_bookings DOES contain B's own
        booking, proving the exclusion is not vacuous.
      Assertion 3 (forged user_id ignored): B calls reserve_room with
        user_id: A's UUID. The created booking's DB user_id is B (server uses
        kiosk.current_user_id(), ignores agent-supplied user_id).

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-hoteling-isolation.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.app — using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_hoteling_development"

    puts "\n── Starting hoteling (isolation test) on #{server_url} ──"

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => kiosk_issuer },
      "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
      out: log, err: log,
    )

    at_exit do
      begin
        Process.kill("TERM", server_pid)
        Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    require "net/http"
    require "uri"
    ready = false
    40.times do
      begin
        res = Net::HTTP.get_response(URI("#{server_url}/.well-known/kiosk.json"))
        if res.code.to_i == 200
          ready = true
          break
        end
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
        nil
      end
      sleep 1
    end
    abort "Server did not become ready — see #{log}" unless ready
    puts "  Server up at #{server_url}"

    flow_rb = File.expand_path("../../isolation_flow.rb", __dir__)
    puts "\n── Running isolation_flow.rb (adversarial cross-tenant) ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "isolation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_a            = result["user_id_a"]
    user_id_b            = result["user_id_b"]
    booking_id_a         = result["booking_id_a"]
    booking_id_b_forged  = result["booking_id_b_forged"]
    b_confirm_booking_rc = result["b_confirm_booking_rc"]
    b_booking_ids        = result["b_booking_ids"] || []

    # ── Assertion 1: B's confirm_booking on A's booking → 403 ────────────
    # B paid for rA (Gate-2 ✓); the 403 isolates Gate-1 ownership exclusively.
    if b_confirm_booking_rc == 403
      puts "  OK  Assertion 1: B's confirm_booking on A's #{booking_id_a} → 403 " \
           "(Gate-1 ownership denied; Gate-2 payment satisfied)"
    else
      failures << "ISOLATION HOLE: B's confirm_booking on A's booking returned " \
                  "#{b_confirm_booking_rc.inspect} (expected 403) — Gate-1 ownership bypass"
      puts "  FAIL  Assertion 1: B's confirm_booking on A's booking expected 403, " \
           "got #{b_confirm_booking_rc.inspect} — isolation hole"
    end

    # ── Assertion 2a: B's my_bookings excludes A's booking ───────────────
    if b_booking_ids.include?(booking_id_a)
      failures << "ISOLATION HOLE: B's my_bookings contains A's booking #{booking_id_a} — cross-tenant leak"
      puts "  FAIL  Assertion 2a: B sees A's booking #{booking_id_a} in my_bookings — isolation hole"
    else
      puts "  OK  Assertion 2a: B's my_bookings excludes A's booking #{booking_id_a} (app-layer isolation)"
    end

    # ── Assertion 2b: B's my_bookings includes B's own booking ───────────
    if b_booking_ids.include?(booking_id_b_forged)
      puts "  OK  Assertion 2b: B's my_bookings includes B's own #{booking_id_b_forged} " \
           "(positive control — exclusion non-vacuous)"
    else
      failures << "B's my_bookings does not include B's own booking #{booking_id_b_forged}; " \
                  "got #{b_booking_ids.inspect} — positive control failed (vacuous exclusion)"
      puts "  FAIL  Assertion 2b: B's my_bookings missing B's own #{booking_id_b_forged} " \
           "— positive control failed"
    end

    # ── Assertion 3: DB user_id on B's forged booking == user_id_b ───────
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM public.bookings WHERE id = '#{booking_id_b_forged}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  OK  Assertion 3: DB bookings.user_id for rB_forged == user_id_b (#{user_id_b}) — forged arg ignored"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB bookings.user_id for rB_forged is A's user_id (#{user_id_a}) " \
                  "— forged user_id arg was NOT ignored"
      puts "  FAIL  Assertion 3: server used forged user_id arg (booking belongs to A, not B)"
    else
      failures << "Unexpected user_id for rB_forged: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  FAIL  Assertion 3: unexpected user_id #{db_user_id.inspect} for rB_forged"
    end

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer isolation holds."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:isolation ─────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery (P4 Task 2) — kiosk-redteam.

    Boots hoteling, runs all 12 Kiosk::Redteam scenarios against the chain
    (no PoW → no KYC → reserve_room → pay → confirm_booking) and asserts
    each applicable attack is BLOCKED:

      BLOCKED  PayForOtherUseSelf    — C2: B pays for A's booking, tries confirm_booking
      BLOCKED  SpentResourceReuse    — C3: re-confirm an already-confirmed booking
      BLOCKED  UnpaidGatedAction     — confirm_booking without payment → Gate-2 fires
      BLOCKED  CrossTenantRead       — B's my_bookings excludes A's rows
      BLOCKED  ForgedUserId          — agent-supplied user_id in reserve_room args ignored
      BLOCKED  MandatePrincipalSwap  — B signs mandate with A's identity; rejected
      BLOCKED  MandateReplay         — B re-submits A's JWS; rejected
      BLOCKED  TokenTampering        — altered JWT claim rejected 401
      SKIPPED  MissingKyc            — hoteling has no KYC gate
      SKIPPED  ExpiredKyc            — hoteling has no KYC gate
      SKIPPED  ForgedKyc             — hoteling has no KYC gate
      SKIPPED  RegistrationWithoutPow — hoteling has no PoW gate

    Exits 0 when all applicable scenarios are BLOCKED and skips match expectations.
    A BREACH = a real hole in hoteling — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-hoteling-redteam.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.app — using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting hoteling (redteam battery) on #{server_url} ──"

    env_vars = { "KIOSK_ISSUER" => kiosk_issuer }

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      env_vars,
      "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
      out: log, err: log,
    )

    at_exit do
      begin
        Process.kill("TERM", server_pid)
        Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    ready = false
    40.times do
      begin
        res = Net::HTTP.get_response(URI("#{server_url}/.well-known/kiosk.json"))
        if res.code.to_i == 200
          ready = true
          break
        end
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
        nil
      end
      sleep 1
    end
    abort "Server did not become ready — see #{log}" unless ready
    puts "  Server up at #{server_url}"

    suite_rb = File.expand_path("../../redteam_suite.rb", __dir__)
    puts "\n── Running redteam_suite.rb ──"

    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"

    system("#{env_str} bundle exec ruby #{suite_rb}")
    exit_status = $?.exitstatus

    if exit_status == 0
      puts "\n  redteam: all applicable scenarios BLOCKED. Exit 0."
    else
      puts "\n  redteam: BREACH DETECTED or error — see output above. Exit #{exit_status}."
      exit exit_status
    end
  end
  # ── end demo:redteam ─────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:schema ─────────────────────────────────────────────────────────────
  desc <<~DESC
    Self-discovery proof (P4 Task 2) — verifies schema + help verbs over HTTP.

    Boots the server, registers a fresh agent (no PoW for hoteling), calls:
      POST /kiosk/exec { command: "schema" }
      POST /kiosk/exec { command: "help"   }

    Asserts:
      • schema.verbs includes query/run/pay/schema/help and NOT events
      • schema.queries includes properties, availability, my_bookings with descriptions
      • schema.actions includes reserve_room, confirm_booking with descriptions
      • help.text mentions reserve_room and confirm_booking by name

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-hoteling-schema.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.app")
      rescue Resolv::ResolvError
        ""
      end
      addr == "127.0.0.1" ? "hoteling.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting hoteling (schema/help proof) on #{server_url} ──"

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => kiosk_issuer },
      "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
      out: log, err: log,
    )

    at_exit do
      begin
        Process.kill("TERM", server_pid)
        Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    ready = false
    40.times do
      begin
        res = Net::HTTP.get_response(URI("#{server_url}/.well-known/kiosk.json"))
        if res.code.to_i == 200
          ready = true
          break
        end
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
        nil
      end
      sleep 1
    end
    abort "Server did not become ready — see #{log}" unless ready
    puts "  Server up at #{server_url}"

    flow_rb = File.expand_path("../../schema_flow.rb", __dir__)
    puts "\n── Running schema_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "schema_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    puts "\n── Schema/help assertions ──"
    failures = []

    verbs   = result["schema_verbs"]   || []
    queries = result["schema_queries"] || []
    actions = result["schema_actions"] || []
    text    = result["help_text"]      || ""

    # Verbs: query/run/pay/schema/help present; events absent
    %w[query run pay schema help].each do |v|
      if verbs.include?(v)
        puts "  OK  schema.verbs includes #{v}"
      else
        failures << "schema.verbs missing #{v} (got #{verbs.inspect})"
        puts "  FAIL  schema.verbs missing #{v}"
      end
    end
    if verbs.include?("events")
      failures << "schema.verbs must NOT include events (got #{verbs.inspect})"
      puts "  FAIL  schema.verbs must NOT include events"
    else
      puts "  OK  schema.verbs does not include events"
    end

    # Queries: properties, availability, my_bookings with descriptions
    %w[properties availability my_bookings].each do |qname|
      entry = queries.find { |q| q["name"] == qname }
      if entry
        puts "  OK  schema.queries includes #{qname}"
        if entry["description"] && !entry["description"].to_s.empty?
          puts "  OK  #{qname} has description: #{entry["description"].inspect}"
        else
          failures << "#{qname} missing description"
          puts "  FAIL  #{qname} missing description"
        end
      else
        failures << "schema.queries missing #{qname}"
        puts "  FAIL  schema.queries missing #{qname}"
      end
    end

    # Actions: reserve_room, confirm_booking with descriptions
    %w[reserve_room confirm_booking].each do |aname|
      entry = actions.find { |a| a["name"] == aname }
      if entry
        puts "  OK  schema.actions includes #{aname}"
        if entry["description"] && !entry["description"].to_s.empty?
          puts "  OK  #{aname} has description: #{entry["description"].inspect}"
        else
          failures << "#{aname} missing description"
          puts "  FAIL  #{aname} missing description"
        end
      else
        failures << "schema.actions missing #{aname}"
        puts "  FAIL  schema.actions missing #{aname}"
      end
    end

    # help text mentions reserve_room and confirm_booking
    %w[reserve_room confirm_booking].each do |name|
      if text.include?(name)
        puts "  OK  help text mentions #{name}"
      else
        failures << "help text does not mention #{name}"
        puts "  FAIL  help text does not mention #{name}"
      end
    end

    if failures.empty?
      puts "\n  All schema/help assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:schema ─────────────────────────────────────────────────────────
end

desc "End-to-end Kiosk hoteling demo: setup the DB then prove the full booking chain."
task demo: ["demo:setup", "demo:book"]
