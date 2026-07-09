# frozen_string_literal: true

# Kiosk demo orchestration. Three sub-tasks:
#
#   rake demo:setup        idempotent db:drop / create / schema:load / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase,
#                          tears down
#   rake demo:isolation    adversarial cross-tenant denial test (R1 Phase 1 T3)
#   rake demo              setup + walkthrough end-to-end
#
# The walkthrough lives in bin/demo (POSIX shell) so it's debuggable
# without going through Rake.

namespace :demo do
  desc "Create + load schema + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    # Path C: schema_format = :sql, so db:schema:load loads structure.sql
    # directly (no RLS). Use db:schema:load instead of db:migrate so that
    # the canonical structure.sql (no ROW LEVEL SECURITY) is the source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc "Boot the server and run the demo walkthrough."
  task :walkthrough do
    exec File.expand_path("../../bin/demo", __dir__)
  end

  # ---------------------------------------------------------------------------
  desc <<~DESC
    Adversarial cross-tenant isolation test (R1 Phase 1 Task 3).

    Runs demo:setup (clean DB + seed), boots the server, runs isolation_flow.rb
    with the two seeded principals (Alice and Bob), and asserts all cross-tenant
    denial properties:

      Assertion 1 (exclusion): B's my_appointments does NOT contain A's appointment aA.
      Assertion 2 (forged user_id ignored): B calls book_appointment with a forged
        user_id arg (A's UUID). The created appointment's DB user_id is B (server
        uses kiosk.current_user_id(), ignores agent-supplied user_id). Verified by:
          - the appointment's DB user_id column == B's user_id (not A's)
          - A's my_appointments does NOT contain B's forged appointment
      Note: book_appointment takes salon_id (open catalogue); no user-owned
        resource target -> ownership-denial assertion does not apply to this surface.

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "json"

    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-saas-booking-isolation.log"
    db   = "kiosk_demo_development"

    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting saas-booking (isolation test) on #{server_url} ──"

    # ── boot the server ────────────────────────────────────────────────
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

    # ── wait for readiness ─────────────────────────────────────────────
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

    # ── run isolation_flow.rb ──────────────────────────────────────────
    flow_rb = File.expand_path("../../isolation_flow.rb", __dir__)
    puts "\n── Running isolation_flow.rb (adversarial cross-tenant) ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "isolation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_a        = result["user_id_a"]
    user_id_b        = result["user_id_b"]
    appt_id_a        = result["appt_id_a"]
    appt_id_b        = result["appt_id_b"]
    b_appt_ids       = result["b_appt_ids"]       || []
    b_appt_ids_after = result["b_appt_ids_after"] || []
    a_appt_ids_after = result["a_appt_ids_after"] || []

    # ── Assertion 1a: B's my_appointments excludes A's appointment ────
    if b_appt_ids.include?(appt_id_a)
      failures << "ISOLATION HOLE: B's my_appointments contains A's appointment #{appt_id_a} — cross-tenant leak"
      puts "  x  Assertion 1a FAILED: B sees A's appointment #{appt_id_a} — isolation hole"
    else
      puts "  OK  Assertion 1a: B's my_appointments excludes A's appointment #{appt_id_a} (app-layer isolation)"
    end

    # ── Assertion 1b: B's my_appointments (after booking) includes B's own ──
    # Positive control: proves the exclusion above is not vacuous. If
    # my_appointments always returned empty for B, Assertion 1a would pass
    # spuriously. Seeing appt_id_b here confirms the query is live for B.
    if b_appt_ids_after.include?(appt_id_b)
      puts "  OK  Assertion 1b: B's my_appointments (after booking) includes B's own #{appt_id_b} (positive control)"
    else
      failures << "B's my_appointments (after booking) does not include B's own appointment #{appt_id_b}; got #{b_appt_ids_after.inspect} — positive control failed (vacuous exclusion)"
      puts "  x  Assertion 1b FAILED: B's my_appointments missing B's own appt_id_b #{appt_id_b} — positive control failed"
    end

    # ── Assertion 2a: A's my_appointments excludes B's forged appointment ──
    if a_appt_ids_after.include?(appt_id_b)
      failures << "ISOLATION HOLE: A's my_appointments contains B's forged appointment #{appt_id_b} — cross-tenant leak"
      puts "  x  Assertion 2a FAILED: A sees B's forged appointment #{appt_id_b} — isolation hole"
    else
      puts "  OK  Assertion 2a: A's my_appointments excludes B's forged appointment #{appt_id_b}"
    end

    # ── Assertion 2b: DB user_id on B's forged appointment == B's UUID ──
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM appointments WHERE id = '#{appt_id_b}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  OK  Assertion 2b: DB appointments.user_id for aB == user_id_b (#{user_id_b}) — forged arg ignored"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB appointments.user_id for aB is A's user_id (#{user_id_a}) — forged user_id arg was NOT ignored"
      puts "  x  Assertion 2b FAILED: server used forged user_id arg (appointment belongs to A, not B)"
    else
      failures << "Unexpected user_id for aB: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  x  Assertion 2b FAILED: unexpected user_id #{db_user_id.inspect} for aB"
    end

    # ── Note: book_appointment surface — no ownership-denial test ─────
    puts "\n  (Note) Ownership-denial assertion: N/A for book_appointment."
    puts "         book_appointment takes salon_id (open catalogue);"
    puts "         no user-owned resource target exists in the Action args."
    puts "         No cross-principal ownership check is applicable to this surface."

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer isolation holds."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
end

desc "End-to-end Kiosk demo: setup the DB then run the walkthrough."
task demo: ["demo:setup", "demo:walkthrough"]

namespace :demo do
  desc <<~DESC
    Registration-PoW demo (KIOSK_POW_REGISTER_DEMO=1).

    Boots the server with the registration gate active and runs register_flow.rb:
    register with no proof → 402; solve the Equihash challenge and resubmit →
    201; the fresh token queries `salons` → 200. Requires python3 + numpy.
  DESC
  task register: :setup do
    require "net/http"; require "uri"; require "json"; require "shellwords"

    abort "numpy not found (pip install numpy)" unless system("python3 -c 'import numpy' 2>/dev/null")

    port         = ENV.fetch("PORT", "3001")
    server_url   = "http://127.0.0.1:#{port}"
    log          = "/tmp/kiosk-saas-register.log"
    flow_rb      = File.expand_path("../../register_flow.rb", __dir__)
    failures     = []

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => server_url, "KIOSK_POW_REGISTER_DEMO" => "1" },
      "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
      out: log, err: log,
    )
    begin
      ready = false
      40.times do
        begin
          ready = true if Net::HTTP.get_response(URI("#{server_url}/.well-known/kiosk.json")).code.to_i == 200
        rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
          nil
        end
        break if ready
        sleep 1
      end
      abort "Server did not become ready — see #{log}" unless ready
      puts "  Server up at #{server_url} (registration PoW active)"

      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{server_url.shellescape}"
      raw = `#{env} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      json_line = raw.lines.grep(/^\{/).last
      puts raw.lines.reject { |l| l.start_with?("{") }.join
      puts json_line if json_line
      result = JSON.parse(json_line || raw) rescue abort("register_flow.rb produced no JSON:\n#{raw}")

      puts "\n══ Registration PoW assertions ══"
      check = lambda do |label, ok|
        if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
      end
      check.call("register without proof → 402",   result["http_register_no_pow"] == 402)
      check.call("register with proof → 201",       result["http_register_solved"] == 201)
      check.call("solved 1 proof",                  result["proofs_solved"].to_i >= 1)
      check.call("fresh token queries salons → 200", result["http_salons"] == 200 && result["salons_rows"].to_i >= 1)
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All registration PoW assertions PASSED."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end

namespace :demo do
  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery — attacks saas-booking's live surface.

    Boots the server and runs redteam_suite.rb against the salon-booking
    surface (salons / my_appointments queries, book_appointment action),
    asserting each attack is BLOCKED:

      BLOCKED  CrossTenantRead  — B's my_appointments excludes A's appointment
      BLOCKED  ForgedUserId     — agent-supplied user_id in book args ignored
      BLOCKED  MissingAuth      — request with no Authorization → 401
      BLOCKED  GarbageToken     — unparseable bearer token → 401
      BLOCKED  UnknownQuery     — unregistered query name → 404
      BLOCKED  UnknownAction    — unregistered action name → 404

    saas-booking has no payment or KYC surface, so the battery covers only the
    attacks the surface can actually exhibit. Exits 0 when all are BLOCKED;
    exits 1 on any BREACH. A BREACH = a real hole — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "net/http"
    require "uri"

    port         = ENV.fetch("PORT", "3001")
    log          = "/tmp/kiosk-saas-booking-redteam.log"
    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting saas-booking (redteam battery) on #{server_url} ──"

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

    suite_rb = File.expand_path("../../redteam_suite.rb", __dir__)
    puts "\n── Running redteam_suite.rb ──"
    system("SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{suite_rb}")
    exit_status = $?.exitstatus

    if exit_status == 0
      puts "\n  redteam: all scenarios BLOCKED. Exit 0."
    else
      puts "\n  redteam: BREACH DETECTED or error — see output above. Exit #{exit_status}."
      exit exit_status
    end
  end
  # ── end demo:redteam ─────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:schema ───────────────────────────────────────────────────────────
  desc <<~DESC
    Self-discovery proof — verifies the schema verb over HTTP.

    Boots the server, authenticates a seeded principal, calls:
      GET /kiosk/schema

    Asserts:
      • schema.verbs includes query/run/pay/schema and NOT events
      • schema.queries includes salons and my_appointments
      • schema.actions includes book_appointment

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "net/http"
    require "uri"
    require "json"

    port         = ENV.fetch("PORT", "3001")
    log          = "/tmp/kiosk-saas-booking-schema.log"
    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting saas-booking (schema proof) on #{server_url} ──"

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

    puts "\n── Schema assertions ──"
    failures = []

    verbs   = result["schema_verbs"]   || []
    queries = (result["schema_queries"] || []).map { |q| q["name"] }
    actions = (result["schema_actions"] || []).map { |a| a["name"] }

    # Verbs: query/run/pay/schema present; events absent.
    %w[query run pay schema].each do |v|
      if verbs.include?(v)
        puts "  ✓  schema.verbs includes #{v}"
      else
        failures << "schema.verbs missing #{v} (got #{verbs.inspect})"
        puts "  ✗  schema.verbs missing #{v}"
      end
    end
    if verbs.include?("events")
      failures << "schema.verbs must NOT include events (got #{verbs.inspect})"
      puts "  ✗  schema.verbs must NOT include events"
    else
      puts "  ✓  schema.verbs does not include events"
    end

    # Queries: salons + my_appointments registered.
    %w[salons my_appointments].each do |q|
      if queries.include?(q)
        puts "  ✓  schema.queries includes #{q}"
      else
        failures << "schema.queries missing #{q} (got #{queries.inspect})"
        puts "  ✗  schema.queries missing #{q}"
      end
    end

    # Actions: book_appointment registered.
    if actions.include?("book_appointment")
      puts "  ✓  schema.actions includes book_appointment"
    else
      failures << "schema.actions missing book_appointment (got #{actions.inspect})"
      puts "  ✗  schema.actions missing book_appointment"
    end

    if failures.empty?
      puts "\n  All schema assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:schema ────────────────────────────────────────────────────────
end
