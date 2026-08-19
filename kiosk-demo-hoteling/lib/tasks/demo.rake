# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-hoteling.
# Tasks:
#
#   rake demo:setup      idempotent db:drop / create / schema:load / seed
#   rake demo:book       boots the server, runs script/hoteling_flow.rb (no-human full
#                        booking chain), asserts happy path + negative gate
#   rake demo:isolation  adversarial cross-tenant isolation test
#   rake demo:redteam    adversarial regression battery (kiosk-redteam)
#   rake demo:schema     self-discovery proof — verifies the schema verb over HTTP
#   rake demo:browse     browse-heavy priced-pagination PoW demo (KIOSK_POW_BROWSE_DEMO=1)
#   rake demo            setup + book (full end-to-end proof)

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

  desc "Boot the server, run script/hoteling_flow.rb end-to-end (happy + payment-gate negative), assert."
  task :book do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"
    require "openssl"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-demo.log"

    # ── host resolution ────────────────────────────────────────────────────
    # The domain here MUST be one config/environments/development.rb permits
    # (config.hosts) — that is the whole point of the lookup. Until K-695 it was
    # <demo>.app, which config.hosts has never listed, so the ONE branch this
    # block exists to offer was the one that broke: a developer who followed the
    # printed /etc/hosts line got Rails 8 HostAuthorization 403s, the 200-only
    # readiness poll below burned its 40 seconds, and the run aborted naming the
    # wrong cause. CI never saw it — with no hosts entry the lookup fails and
    # everything dials 127.0.0.1.
    #
    # This name resolves PUBLICLY to the live demo box, so a bare lookup returns
    # a public IP, not an error. Only 127.0.0.1 is accepted, which is exactly
    # what an /etc/hosts entry produces: a local harness can never be steered
    # onto the deployed host by whatever DNS happens to answer.
    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.demo.kiosk.tech — using 127.0.0.1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_hoteling_development"
    flow_rb      = File.expand_path("../../script/hoteling_flow.rb", __dir__)

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

    # Helper: run script/hoteling_flow.rb with the given env vars; return parsed JSON result.
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
        abort "script/hoteling_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
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

      # ── confirmation_code is PERSISTED, not minted for the response (K-698)
      # It was a fresh SecureRandom.uuid handed to the assistant while the
      # UPDATE wrote only status — against a table with no such column — so the
      # hotel issued a reference it kept no record of and could not match at
      # the desk. Three assertions, because "present" was already true before
      # the fix and proved nothing: the code comes back, my_bookings reports the
      # SAME string afterwards, and the bookings row actually holds it.
      code        = result["confirmation_code"].to_s
      stored_code = result["stored_confirmation_code"].to_s
      if !code.empty? && stored_code == code
        puts "  OK  confirmation_code round-trips through my_bookings (#{code})"
      else
        failures << "happy: confirmation_code #{code.inspect} != my_bookings' #{stored_code.inspect}"
        puts "  FAIL  confirmation_code #{code.inspect} != my_bookings' #{stored_code.inspect}"
      end

      db_code = `psql -X -d #{db} -tAc "SELECT confirmation_code FROM public.bookings WHERE id = '#{booking_id}'" 2>&1`.strip
      if !code.empty? && db_code == code
        puts "  OK  bookings.confirmation_code == the code returned (#{db_code})"
      else
        failures << "happy: bookings.confirmation_code #{db_code.inspect} != returned #{code.inspect}"
        puts "  FAIL  bookings.confirmation_code #{db_code.inspect} != returned #{code.inspect}"
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
    Adversarial cross-tenant isolation test.

    Runs demo:setup (clean DB + seed), boots the server, runs script/isolation_flow.rb
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
      Assertion 3a (the principal is not an input): B calls reserve_room with a
        forged user_id arg (A's UUID) -> 400 bad_request naming user_id,
        refused by the published input_schema before the handler runs.
      Assertion 3b (ownership comes from the token): B's legitimate booking has
        DB user_id == B, because the INSERT reads kiosk.current_user_id() and
        never an argument — the property the refusal alone does not prove.

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-isolation.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.demo.kiosk.tech — using 127.0.0.1)"
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

    flow_rb = File.expand_path("../../script/isolation_flow.rb", __dir__)
    puts "\n── Running script/isolation_flow.rb (adversarial cross-tenant) ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "script/isolation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_a            = result["user_id_a"]
    user_id_b            = result["user_id_b"]
    booking_id_a         = result["booking_id_a"]
    booking_id_b         = result["booking_id_b"]
    forged_refusal       = result["forged_refusal"] || []
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
    if b_booking_ids.include?(booking_id_b)
      puts "  OK  Assertion 2b: B's my_bookings includes B's own #{booking_id_b} " \
           "(positive control — exclusion non-vacuous)"
    else
      failures << "B's my_bookings does not include B's own booking #{booking_id_b}; " \
                  "got #{b_booking_ids.inspect} — positive control failed (vacuous exclusion)"
      puts "  FAIL  Assertion 2b: B's my_bookings missing B's own #{booking_id_b} " \
           "— positive control failed"
    end

    # ── Assertion 3a: the forged user_id is REFUSED by the published contract.
    # On the 0.4 wire `reserve_room` publishes `additionalProperties: false` and
    # does not declare `user_id` — the principal is not one of its inputs — so
    # the forgery is a typed 400 naming the parameter, before the handler runs.
    # (Through 0.3 the argument was accepted and silently ignored, and the desc
    # said so; that sentence is now false.)
    forged_rc, forged_code, forged_detail = forged_refusal
    if forged_rc == 400 && forged_code == "bad_request" && forged_detail.to_s.include?("user_id")
      puts "  OK  Assertion 3a: forged user_id → 400 bad_request naming user_id " \
           "(refused by input_schema before the handler runs)"
    else
      failures << "forged user_id not refused: #{forged_refusal.inspect}, " \
                  "want [400, \"bad_request\", …user_id…]"
      puts "  FAIL  Assertion 3a: forged user_id → #{forged_refusal.inspect}"
    end

    # ── Assertion 3b: ownership comes from the TOKEN — DB user_id == B ───
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM public.bookings WHERE id = '#{booking_id_b}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  OK  Assertion 3b: DB bookings.user_id for rB == user_id_b (#{user_id_b}) — ownership taken from the identity"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB bookings.user_id for rB is A's user_id (#{user_id_a}) " \
                  "— ownership was not taken from the authenticated identity"
      puts "  FAIL  Assertion 3b: booking belongs to A, not B"
    else
      failures << "Unexpected user_id for rB: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  FAIL  Assertion 3b: unexpected user_id #{db_user_id.inspect} for rB"
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
    Adversarial regression battery — kiosk-redteam.

    Boots hoteling, runs the 13 generic Kiosk::Redteam scenarios plus 7 hoteling
    beats against the chain (register PoW → no KYC → reserve_room → pay →
    confirm_booking) and asserts each applicable attack is BLOCKED:

      BLOCKED  PayForOtherUseSelf    — C2: B pays for A's booking, tries confirm_booking
      BLOCKED  SpentResourceReuse    — C3: re-confirm an already-confirmed booking
      BLOCKED  UnpaidGatedAction     — confirm_booking without payment → Gate-2 fires
      BLOCKED  CrossTenantRead       — B's my_bookings excludes A's rows
      BLOCKED  ForgedUserId          — agent-supplied user_id in reserve_room args refused
                                       (0.4: undeclared argument → typed 400 before the handler)
      BLOCKED  MandatePrincipalSwap  — B signs mandate with A's identity; rejected
      BLOCKED  MandateReplay         — B re-submits A's JWS; rejected
      BLOCKED  TokenTampering        — altered JWT claim rejected 401
      BLOCKED  PrivilegeSelfSelection — client-chosen registration role ignored (server-pinned)
      BLOCKED  RegistrationWithoutPow — register without a proof rejected (register PoW is ON)
      BLOCKED  WrongCurrencyCart     — usd cart at a EUR operator refused at capture
      BLOCKED  TamperedPriceCart     — below-quote total refused at capture
      BLOCKED  InflatedTotalCart     — total above the line-item sum refused at capture
      BLOCKED  MalformedUuidArg      — junk booking_id → typed 400, no SQL internals, never a 500
      BLOCKED  DoubleBookedRoom      — a held room-night cannot be re-reserved → 409
      BLOCKED  RetiredWire           — POST /kiosk/query and /kiosk/run are an ordinary 404
                                       (the 0.3 pair was DELETED, not shimmed — T-074 = A)
      BLOCKED  MethodMismatch        — a GET at an action's path is 405 method_not_allowed
                                       with Allow:, never a silent 404
      SKIPPED  MissingKyc            — hoteling has no KYC gate
      SKIPPED  ExpiredKyc            — hoteling has no KYC gate
      SKIPPED  ForgedKyc             — hoteling has no KYC gate

    Exits 0 when all applicable scenarios are BLOCKED and skips match expectations.
    A BREACH = a real hole in hoteling — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-redteam.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.demo.kiosk.tech — using 127.0.0.1)"
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

    suite_rb = File.expand_path("../../script/redteam_suite.rb", __dir__)
    puts "\n── Running script/redteam_suite.rb ──"

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
    Self-discovery proof — verifies the schema verb over HTTP.

    Boots the server, registers a fresh agent (registration IS PoW-gated —
    registration_pow_count = 1 — and the flow solves it transparently), calls:
      GET /kiosk/schema

    Asserts:
      • `GET /kiosk/schema` answers 200 with NO Authorization header (public since T-094)
      • the MODULE set lives in /.well-known/kiosk.json `capabilities` (`verbs` dropped, T-095)
      • capabilities is the MODULE set schema/queries/actions/pay and NOT events
      • schema.queries includes properties, availability, my_bookings with descriptions
      • schema.actions includes reserve_room, confirm_booking, payment_setup with descriptions

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-schema.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      addr == "127.0.0.1" ? "hoteling.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting hoteling (schema proof) on #{server_url} ──"

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

    flow_rb = File.expand_path("../../script/schema_flow.rb", __dir__)
    puts "\n── Running script/schema_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "script/schema_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    puts "\n── Schema assertions ──"
    failures = []

    queries      = result["schema_queries"] || []
    actions      = result["schema_actions"] || []
    capabilities = result["discovery_capabilities"] || []

    # THE SCHEMA CALL WAS MADE WITHOUT A CREDENTIAL (T-094). The flow driver
    # sends no Authorization header, so this status IS the public-access proof.
    if result["schema_status"] == 200
      puts "  OK  GET /kiosk/schema answered 200 with NO Authorization header"
    else
      failures << "unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}, want 200"
      puts "  FAIL  unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}"
    end

    # THE MODULE SET, at its one remaining home. It was published twice —
    # `schema.verbs` and `kiosk.json` `capabilities` — from the same call, so
    # `verbs` was dropped (T-095) and the property moved here intact.
    %w[schema queries actions pay].each do |v|
      if capabilities.include?(v)
        puts "  OK  capabilities includes #{v}"
      else
        failures << "capabilities missing #{v} (got #{capabilities.inspect})"
        puts "  FAIL  capabilities missing #{v}"
      end
    end
    if capabilities.include?("events")
      failures << "capabilities must NOT include events (got #{capabilities.inspect})"
      puts "  FAIL  capabilities must NOT include events"
    else
      puts "  OK  capabilities does not include events"
    end

    # Queries: properties, availability, my_bookings, search_hotels, hotel_detail
    %w[properties availability my_bookings search_hotels hotel_detail].each do |qname|
      entry = queries.find { |q| q["name"] == qname }
      if entry
        puts "  OK  schema.queries includes #{qname}"
        if entry["description"] && !entry["description"].to_s.empty?
          puts "  OK  #{qname} has description: #{entry["description"].inspect[0, 80]}…"
        else
          failures << "#{qname} missing description"
          puts "  FAIL  #{qname} missing description"
        end
      else
        failures << "schema.queries missing #{qname}"
        puts "  FAIL  schema.queries missing #{qname}"
      end
    end

    # T-042 / K-452: the two data-plane exemplar queries carry the machine-readable
    # descriptor extensions (input_schema + example_params + example_row).
    %w[search_hotels hotel_detail].each do |qname|
      entry = queries.find { |q| q["name"] == qname } || {}
      %w[input_schema example_params example_row].each do |ext|
        if entry[ext] && !entry[ext].to_s.empty?
          puts "  OK  #{qname} advertises #{ext}"
        else
          failures << "#{qname} missing #{ext}"
          puts "  FAIL  #{qname} missing #{ext}"
        end
      end
    end

    # Actions: reserve_room, confirm_booking, payment_setup with descriptions
    %w[reserve_room confirm_booking payment_setup].each do |aname|
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

    if failures.empty?
      puts "\n  All schema assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:schema ─────────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:search ─────────────────────────────────────────────────────────────
  desc <<~DESC
    Pagination + detail-by-id proof (T-042 / K-452).

    Boots the server over the ~100-hotel catalogue, registers a fresh agent, and
    runs script/search_flow.rb to PROVE the data-plane pagination shape:

      • search_hotels with a small limit returns a FULL page — a BARE ARRAY —
        carrying an RFC 8288 `Link: <…>; rel="next"` header (truncated) and an
        `X-Total-Count` larger than the page.
      • FOLLOWING that link verbatim returns the FOLLOWING page, and the two
        pages are DISJOINT (real paging, not the same slice).
      • a filtered search that fits in one page is the SAME bare array with no
        `Link` at all (complete result — the link's absence is the signal).
      • hotel_detail on a summary row's id returns a ONE-ROW ARRAY carrying the
        full property with rooms (the "search returns summaries, fetch detail on
        demand" pattern; K-794 made it answer rows like every other query), and
        an id nobody has is 404 not_found on BOTH hotel_detail and availability
        (T-090: that argument addresses a property, so an empty list would be a
        false statement rather than an empty result).

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task search: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-search.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      addr == "127.0.0.1" ? "hoteling.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting hoteling (pagination proof) on #{server_url} ──"

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

    flow_rb = File.expand_path("../../script/search_flow.rb", __dir__)
    puts "\n── Running script/search_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "script/search_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    puts "\n── Pagination + detail assertions ──"
    failures = []

    check = lambda do |ok, pass_msg, fail_msg|
      if ok
        puts "  OK  #{pass_msg}"
      else
        failures << fail_msg
        puts "  FAIL  #{fail_msg}"
      end
    end

    check.call(result["http_page1"] == 200, "search_hotels page 1 → 200", "page 1 HTTP #{result["http_page1"].inspect}")

    # THE pagination proof (T-092): every page is a BARE ARRAY; a truncated one
    # carries `Link: …; rel="next"`; following that link verbatim returns a
    # DISJOINT next page; the last (filtered, complete) page carries no link.
    check.call(result["page1_count"] == 20,
               "page 1 is a full page of 20 rows", "page 1 count #{result["page1_count"].inspect} (expected 20)")
    check.call(result["page1_is_array"] == true,
               "page 1 is a BARE ARRAY — a paginating query has no shape of its own",
               "page 1 is not a bare array (#{result["page1_is_array"].inspect}) — the " \
               "`{rows, next}` object was supposed to go with RFC 8288")
    check.call(!result["page1_next"].to_s.empty?,
               "page 1 carries Link rel=\"next\" (truncated) — #{result["page1_next"].inspect}",
               "page 1 has no Link rel=\"next\" — truncation is silent")
    check.call(result["page1_total"].to_i > result["page1_count"].to_i,
               "X-Total-Count (#{result["page1_total"].inspect}) counts the MATCHING set, " \
               "not the page (#{result["page1_count"]})",
               "X-Total-Count #{result["page1_total"].inspect} is not larger than the page " \
               "#{result["page1_count"].inspect} — it must count matching rows, never returned ones")
    check.call(result["page2_count"].to_i >= 1 && result["pages_disjoint"] == true,
               "FOLLOWING the Link target returns a DISJOINT next page (#{result["page2_count"]} rows)",
               "next page empty or overlapping (count=#{result["page2_count"].inspect}, disjoint=#{result["pages_disjoint"].inspect})")
    check.call(result["filtered_has_next"] == false && result["filtered_is_array"] == true,
               "the filtered (complete) search is the SAME bare array and carries no Link " \
               "(#{result["filtered_count"]} rows)",
               "filtered search is not a bare array without a `next` link " \
               "(array=#{result["filtered_is_array"].inspect}, link=#{result["filtered_has_next"].inspect}) " \
               "— cannot signal completeness")
    check.call(result["filtered_total"].to_i == result["filtered_count"].to_i,
               "a COMPLETE answer's X-Total-Count equals its row count (#{result["filtered_count"]})",
               "complete answer X-Total-Count #{result["filtered_total"].inspect} != " \
               "row count #{result["filtered_count"].inspect}")

    # detail-by-id: search returns summaries, fetch detail on demand.
    check.call(result["http_detail"] == 200 && result["detail_room_count"].to_i >= 1,
               "hotel_detail(id=#{result["detail_id"]}) → full property, #{result["detail_room_count"]} room type(s)",
               "hotel_detail failed (http=#{result["http_detail"].inspect}, rooms=#{result["detail_room_count"].inspect})")

    # K-794: a detail-by-id query is still a query, so it answers ROWS — a
    # one-element array, not a bare object. Both halves are asserted, because
    # the shape without the empty case would leave "no such hotel" undefined.
    check.call(result["detail_is_array"] == true && result["detail_row_count"] == 1,
               "hotel_detail answers a ONE-ROW ARRAY (spec §8.2)",
               "hotel_detail is not a one-row array " \
               "(array=#{result["detail_is_array"].inspect}, rows=#{result["detail_row_count"].inspect})")
    # T-090 / spec §9.1: `property_id` ADDRESSES a property, so an id nobody has
    # is 404 — on BOTH verbs that take it. The pair used to disagree, which is
    # what made the rule Phil's call.
    check.call(result["http_unknown_detail"] == 404 &&
               result["unknown_detail_code"] == "not_found",
               "hotel_detail for an id nobody has → 404 not_found",
               "hotel_detail for an unknown id answered " \
               "http=#{result["http_unknown_detail"].inspect} " \
               "code=#{result["unknown_detail_code"].inspect} (want 404 / not_found)")
    check.call(result["http_unknown_availability"] == 404 &&
               result["unknown_availability_code"] == "not_found",
               "availability for the SAME unknown id → 404 not_found (the two verbs agree)",
               "availability for an unknown id answered " \
               "http=#{result["http_unknown_availability"].inspect} " \
               "code=#{result["unknown_availability_code"].inspect} (want 404 / not_found)")

    if failures.empty?
      puts "\n  All pagination + detail assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:search ─────────────────────────────────────────────────────────
end

desc "End-to-end Kiosk hoteling demo: setup the DB then prove the full booking chain."
task demo: ["demo:setup", "demo:book"]

namespace :demo do
  desc <<~DESC
    Browse-heavy priced-pagination PoW demo (KIOSK_POW_BROWSE_DEMO=1).

    Boots the server with the browse gate active and runs script/browse_flow.rb: a
    burst of `properties` queries where the first few are free and each extra
    one costs escalating proof-of-work (price depth, don't ban it).

    Asserts: a non-empty free prefix, the demanded proof count becomes positive,
    and the curve is monotonic non-decreasing. Requires python3 + numpy.
  DESC
  task browse: :setup do
    require "net/http"; require "uri"; require "json"; require "shellwords"

    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    abort "numpy not found. Install with: pip install numpy" unless python_ok

    port         = ENV.fetch("PORT", "3003")
    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url
    log          = "/tmp/kiosk-hoteling-browse.log"
    flow_rb      = File.expand_path("../../script/browse_flow.rb", __dir__)
    failures     = []

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => kiosk_issuer, "KIOSK_POW_BROWSE_DEMO" => "1" },
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
      puts "  Server up at #{server_url} (browse gate active)"

      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape}"
      raw = `#{env} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      json_line = raw.lines.grep(/^\{/).last
      puts raw.lines.reject { |l| l.start_with?("{") }.join
      puts json_line if json_line
      result = JSON.parse(json_line || raw) rescue abort("script/browse_flow.rb produced no JSON:\n#{raw}")

      puts "\n══ Browse priced-pagination assertions ══"
      puts "  Proof-count curve: #{result["curve"].inspect}"

      if result["free_prefix"].to_i >= 1
        puts "  OK  free prefix (#{result["free_prefix"]} queries served without PoW)"
      else
        failures << "expected a non-empty free prefix, curve=#{result["curve"].inspect}"
        puts "  FAIL  no free prefix"
      end
      if result["became_priced"]
        puts "  OK  depth got priced (proof count rose above 0)"
      else
        failures << "expected the proof count to become positive, curve=#{result["curve"].inspect}"
        puts "  FAIL  browsing never got priced"
      end
      if result["monotonic"]
        puts "  OK  proof count is monotonic non-decreasing"
      else
        failures << "expected a monotonic curve, got #{result["curve"].inspect}"
        puts "  FAIL  proof count not monotonic"
      end
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All browse assertions PASSED — depth priced, not banned."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end
