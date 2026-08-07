# frozen_string_literal: true

# Kiosk demo orchestration (atablefor — restaurant table-booking). Tasks:
#
#   rake demo:setup        idempotent db:drop / create / schema:load / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase, tears down
#   rake demo:book         boots the server, runs book_flow.rb (no-human table booking),
#                          asserts the confirmed booking, tears down
#   rake demo:pow          boots with KIOSK_POW_DEMO=1, runs pow_flow.rb (402→solve→200)
#   rake demo:reputation   anti-scalping PoW demo (cost drops as bookings accrue)
#   rake demo:backoff      count-based PoW backoff (solve once → next N calls free →
#                          re-challenge; KIOSK_POW_BACKOFF_DEMO=1)
#   rake demo:binding      account-binding: a diner links their assistant, whose
#                          booking then ties to the diner's account
#   rake demo:isolation    adversarial cross-tenant isolation test
#   rake demo:schema       self-discovery proof — verifies the schema verb + pay-absent
#   rake demo:redteam      adversarial regression battery
#   rake demo              setup + book (the full end-to-end proof)
#
# atablefor takes NO payments (a reservation needs none), so there is no
# demo:rls / demo:order / pay path — the RLS *showcase* lives in getgrocery.
# The walkthrough lives in bin/demo (POSIX shell) so it's debuggable without
# going through Rake.

namespace :demo do
  desc "Create + load schema + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    # Path C: schema_format = :sql, so db:schema:load loads structure.sql
    # directly. Use db:schema:load instead of db:migrate so the canonical
    # structure.sql is the source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc "Boot the server and run the curl demo walkthrough."
  task walkthrough: :setup do
    exec File.expand_path("../../bin/demo", __dir__)
  end

  desc "Boot the server, run the no-human book_flow.rb end-to-end, assert the booking."
  task :book do
    require "resolv"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-demo.log"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = Resolv.getaddress("atablefor.app") rescue ""
      if addr == "127.0.0.1"
        "atablefor.app"
      else
        puts "  add to /etc/hosts:  127.0.0.1 atablefor.app" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor on #{server_url} ──"

    # ── boot the server ────────────────────────────────────────────────
    env_vars = {
      "KIOSK_ISSUER" => kiosk_issuer,
    }
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
    end

    # ── wait for readiness ─────────────────────────────────────────────
    require "net/http"
    require "uri"
    ready = false
    30.times do
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

    # ── run book_flow.rb ───────────────────────────────────────────────
    flow_rb = File.expand_path("../../book_flow.rb", __dir__)
    puts "\n── Running book_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "book_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    # ── assertions: HTTP + JSON ────────────────────────────────────────
    puts "\n── Assertions ──"
    failures = []

    booking     = result["booking"]     || {}
    my_bookings = result["my_bookings"] || []

    booking_id = booking["booking_id"]
    if booking_id && !booking_id.empty?
      puts "  ✓  booking.booking_id present (#{booking_id})"
    else
      failures << "booking.booking_id missing"
      puts "  ✗  booking.booking_id missing"
    end

    if booking["status"] == "confirmed"
      puts "  ✓  booking.status == confirmed"
    else
      failures << "booking.status expected 'confirmed', got #{booking["status"].inspect}"
      puts "  ✗  booking.status — got #{booking["status"].inspect}"
    end

    if booking["party_size"] == 2
      puts "  ✓  booking.party_size == 2 (a table for two)"
    else
      failures << "booking.party_size expected 2, got #{booking["party_size"].inspect}"
      puts "  ✗  booking.party_size — got #{booking["party_size"].inspect}"
    end

    # my_bookings must show exactly the one confirmed booking just made.
    if my_bookings.size == 1 && my_bookings.first["booking_id"] == booking_id && my_bookings.first["status"] == "confirmed"
      puts "  ✓  my_bookings shows the confirmed booking (id=#{booking_id})"
    else
      failures << "my_bookings expected [{id:#{booking_id}, status:confirmed}], got #{my_bookings.inspect}"
      puts "  ✗  my_bookings — got #{my_bookings.inspect}"
    end

    # ── assertions: psql ground truth ──────────────────────────────────
    # Assert the SPECIFIC booking just made (by id), not DB-wide totals: the
    # seeds place a couple of existing reservations on the public board, so an
    # absolute COUNT is seed-dependent. This checks the new row directly.
    db = "kiosk_atablefor_development"

    this_booking = `psql -X -d #{db} -tAc "SELECT status FROM bookings WHERE id = '#{booking_id}'" 2>&1`.strip
    if this_booking == "confirmed"
      puts "  ✓  the new booking is confirmed in the DB (id=#{booking_id})"
    else
      failures << "new booking #{booking_id} status expected 'confirmed', got #{this_booking.inspect}"
      puts "  ✗  new booking status — got #{this_booking.inspect}"
    end

    # The slot this booking claimed must be marked 'booked' (no double-booking).
    this_slot = `psql -X -d #{db} -tAc "SELECT ts.status FROM table_slots ts JOIN bookings b ON b.table_slot_id = ts.id WHERE b.id = '#{booking_id}'" 2>&1`.strip
    if this_slot == "booked"
      puts "  ✓  the booked table_slot is marked booked"
    else
      failures << "the new booking's table_slot status expected 'booked', got #{this_slot.inspect}"
      puts "  ✗  the new booking's table_slot status — got #{this_slot.inspect}"
    end

    if failures.empty?
      puts "\n  All assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end

  desc "Boot the server with KIOSK_POW_DEMO=1, run pow_flow.rb (402→solve.py→200 + wrong-nonce→403)."
  task :pow do
    # Requirement: python3 with numpy (the equihash solver is vectorised).
    # Install with: pip install numpy
    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    unless python_ok
      abort "numpy not found. Install with: pip install numpy\n" \
            "Then re-run: bundle exec rake demo:pow"
    end

    require "resolv"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-pow-demo.log"

    host = begin
      addr = Resolv.getaddress("atablefor.app") rescue ""
      addr == "127.0.0.1" ? "atablefor.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (PoW demo) on #{server_url} ──"

    env_vars = {
      "KIOSK_ISSUER"   => kiosk_issuer,
      "KIOSK_POW_DEMO" => "1",
    }
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
    end

    # Wait for readiness.
    require "net/http"
    require "uri"
    ready = false
    30.times do
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
    puts "  Server up at #{server_url} (PoW active)"

    # Run pow_flow.rb.
    flow_rb = File.expand_path("../../pow_flow.rb", __dir__)
    puts "\n── Running pow_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "pow_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    # ── Assertions ──
    puts "\n── PoW assertions ──"
    failures = []

    if result["http_challenge"] == 402
      puts "  ✓  query challenged: HTTP 402 (pow_required)"
    else
      failures << "expected http_challenge=402, got #{result["http_challenge"].inspect}"
      puts "  ✗  expected HTTP 402, got #{result["http_challenge"].inspect}"
    end

    if result["served"] == true && result["http_served_after_solve"] == 200
      puts "  ✓  served after real solve.py: HTTP 200, #{result["availability_rows"]} open slots"
    else
      failures << "expected served=true + http_served_after_solve=200, got #{result.slice("served","http_served_after_solve").inspect}"
      puts "  ✗  not served after solve: #{result.inspect}"
    end

    if result["http_wrong_nonce"] == 403
      puts "  ✓  wrong nonce rejected: HTTP 403"
    else
      failures << "expected http_wrong_nonce=403, got #{result["http_wrong_nonce"].inspect}"
      puts "  ✗  wrong nonce returned #{result["http_wrong_nonce"].inspect}"
    end

    bpc = result["bad_proof_count"].to_i
    if bpc >= 1
      puts "  ✓  on_bad_proof penalized: bad_proof_count=#{bpc}"
    else
      failures << "expected bad_proof_count>=1 after wrong nonce, got #{bpc}"
      puts "  ✗  bad_proof_count=#{bpc} (expected >=1)"
    end

    if failures.empty?
      puts "\n  All PoW assertions passed."
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end

  # ── demo:reputation ────────────────────────────────────────────────────────
  desc <<~DESC
    Anti-scalping reputation PoW demo (trust earned by booking).

    Boots the server with KIOSK_POW_REPUTATION_DEMO=1, runs reputation_flow.rb:
      0 confirmed bookings → 402 with 2 equihash challenges (unproven)
      1 confirmed booking  → 402 with 1 challenge (a booking earns relief)
      2 confirmed bookings → 200 served directly, NO challenge (proven — free pass)

    The anti-reservation-scalping mechanic: a fresh / low-reputation agent pays
    escalating PoW to probe prime-time availability; a scalper renting fresh
    identities pays and pays, while a returning diner earns relief.

    Asserts:
      • proofs_unproven > proofs_after_1_booking  (cost dropped with a booking)
      • served_after_2_bookings == true           (query is free once proven)
      • challenge_after_2 == nil                   (no PoW issued to a proven principal)

    Policy: Kiosk::Reputation::Policies::RateAndReputation
      proven_purchases_threshold: 2, base_count: 1, unproven_count_bonus: 1
    Factors: real DB lookup — COUNT(*) FROM bookings WHERE user_id = <principal>
             AND status = 'confirmed' (mapped into the policy's proven-count factor)

    Requirements:
      python3 with numpy: pip install numpy
  DESC
  task :reputation do
    # Requirement: python3 with numpy (the equihash solver is vectorised).
    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    unless python_ok
      abort "numpy not found. Install with: pip install numpy\n" \
            "Then re-run: bundle exec rake demo:reputation"
    end

    require "resolv"

    port = ENV.fetch("PORT", "3004")  # port 3004 to avoid conflict with demo:pow (3002)
    log  = "/tmp/kiosk-atablefor-reputation-demo.log"

    host = begin
      addr = Resolv.getaddress("atablefor.app") rescue ""
      addr == "127.0.0.1" ? "atablefor.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (anti-scalping reputation PoW demo) on #{server_url} ──"
    puts "   Policy: RateAndReputation (proven_purchases_threshold=2, base_count=1, unproven_count_bonus=1)"
    puts "   Factors: real DB lookup — bookings WHERE user_id = <principal> AND status = 'confirmed'"
    puts "   Expected curve (by PROOF COUNT, N×PoW): 2 proofs (0 bookings) → 1 proof (1 booking) → free pass (2 bookings)"

    env_vars = {
      "KIOSK_ISSUER"               => kiosk_issuer,
      "KIOSK_POW_REPUTATION_DEMO"  => "1",
    }
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
    end

    # Wait for readiness.
    require "net/http"
    require "uri"
    ready = false
    30.times do
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
    puts "  Server up at #{server_url} (Reputation PoW active)"

    # Run reputation_flow.rb.
    flow_rb = File.expand_path("../../reputation_flow.rb", __dir__)
    puts "\n── Running reputation_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "reputation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    # ── Assertions ──
    puts "\n── Reputation PoW assertions ──"
    failures = []

    n_unproven = result["proofs_unproven"]
    n_after_1  = result["proofs_after_1_booking"]
    served_2   = result["served_after_2_bookings"]
    n_after_2  = result["challenge_after_2"]

    puts "  Proof-count curve: #{n_unproven} (0 bookings) → #{n_after_1} (1 booking) → #{n_after_2.inspect} (2 bookings)"

    if n_unproven.to_i > n_after_1.to_i
      puts "  ✓  proof count dropped: #{n_unproven} → #{n_after_1} (a booking earns relief)"
    else
      failures << "expected proofs_unproven(#{n_unproven}) > proofs_after_1_booking(#{n_after_1}) — cost must drop after first booking"
      puts "  ✗  proof count did NOT drop after 1st booking: #{n_unproven} → #{n_after_1}"
    end

    if served_2 == true && n_after_2.nil?
      puts "  ✓  free pass after 2 bookings: query served without any challenge (proven principal)"
    else
      failures << "expected served_after_2_bookings=true + challenge_after_2=nil; got served=#{served_2.inspect}, challenge=#{n_after_2.inspect}"
      puts "  ✗  NOT served without challenge after 2 bookings (served=#{served_2.inspect}, n_after_2=#{n_after_2.inspect})"
    end

    if failures.empty?
      puts "\n  All reputation assertions PASSED."
      puts "  Anti-scalping: PoW proof-count curve demonstrated end-to-end (cost drops as a real booking history accrues)."
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:reputation ────────────────────────────────────────────────────

  # ── demo:backoff ───────────────────────────────────────────────────────────
  desc <<~DESC
    COUNT-BASED PoW backoff demo — "solve once, next N calls free" (POW-RECENCY-GRACE).

    Boots the server with KIOSK_POW_BACKOFF_DEMO=1, runs backoff_flow.rb:
      fresh identity queries → 402 (pow_required, no grant yet)
      solves via the bundled solver, resubmits → 200 (proof verified → grant set to 3)
      the NEXT 3 requests are served WITHOUT a challenge (200 — the grant consumed)
      the 4th request is challenged again (402 — the grant is exhausted)

    A COUNT (not a time window) is deliberate: a window would let a bot flood
    thousands of requests inside it; a count caps exactly how many free calls one
    ~9 s solve buys, then the toll returns.

    Asserts:
      • http_first_challenge == 402       (a fresh identity is tolled)
      • http_served_after_solve == 200    (a solve verifies and sets the grant)
      • free_call_statuses == [200,200,200] (the 3 granted follow-ups are free)
      • http_after_grant == 402           (the 4th is re-challenged)

    Policy: Kiosk::Reputation::Policies::Backoff.new(count: 3, base: {equihash, count: 1})
    Store:  the in-process BackoffStore — authoritative per worker; a multi-worker
            deploy needs a shared store (Redis/DB) or the grant is only per-worker.

    Requirements:
      python3 with numpy: pip install numpy
  DESC
  task :backoff do
    # Requirement: python3 with numpy (the equihash solver is vectorised).
    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    unless python_ok
      abort "numpy not found. Install with: pip install numpy\n" \
            "Then re-run: bundle exec rake demo:backoff"
    end

    require "resolv"

    port = ENV.fetch("PORT", "3006")  # distinct port (pow=3002, reputation=3004)
    log  = "/tmp/kiosk-atablefor-backoff-demo.log"

    host = begin
      addr = Resolv.getaddress("atablefor.app") rescue ""
      addr == "127.0.0.1" ? "atablefor.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (count-based PoW backoff demo) on #{server_url} ──"
    puts "   Policy: Backoff (count=3) — one solve buys the next 3 calls free, then re-challenge"

    env_vars = {
      "KIOSK_ISSUER"            => kiosk_issuer,
      "KIOSK_POW_BACKOFF_DEMO"  => "3", # the value is the free-call count; the flow asserts exactly 3
    }
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
    end

    # Wait for readiness.
    require "net/http"
    require "uri"
    ready = false
    30.times do
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
    puts "  Server up at #{server_url} (backoff PoW active)"

    flow_rb = File.expand_path("../../backoff_flow.rb", __dir__)
    puts "\n── Running backoff_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "backoff_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    # ── Assertions ──
    puts "\n── Backoff PoW assertions ──"
    failures = []

    if result["http_first_challenge"] == 402
      puts "  ✓  fresh identity tolled: HTTP 402 (pow_required, no grant yet)"
    else
      failures << "expected http_first_challenge=402, got #{result["http_first_challenge"].inspect}"
      puts "  ✗  first query not challenged: #{result["http_first_challenge"].inspect}"
    end

    if result["http_served_after_solve"] == 200
      puts "  ✓  served after real solve.py: HTTP 200 (proof verified → grant set to #{result["grant_count"]})"
    else
      failures << "expected http_served_after_solve=200, got #{result["http_served_after_solve"].inspect}"
      puts "  ✗  not served after solve: #{result["http_served_after_solve"].inspect}"
    end

    free = result["free_call_statuses"] || []
    if free.size == result["grant_count"] && free.all? { |s| s == 200 }
      puts "  ✓  the next #{result["grant_count"]} calls served WITHOUT a challenge (#{free.inspect}) — grant consumed"
    else
      failures << "expected #{result["grant_count"]} free 200s after the solve, got #{free.inspect}"
      puts "  ✗  granted follow-ups not all free: #{free.inspect}"
    end

    if result["http_after_grant"] == 402
      puts "  ✓  grant exhausted → the next call is re-challenged: HTTP 402"
    else
      failures << "expected http_after_grant=402, got #{result["http_after_grant"].inspect}"
      puts "  ✗  grant did not expire — 4th call returned #{result["http_after_grant"].inspect}"
    end

    if failures.empty?
      puts "\n  All backoff assertions PASSED."
      puts "  Solve once → next #{result["grant_count"]} calls free → re-challenge. Count-based grant demonstrated end-to-end."
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:backoff ───────────────────────────────────────────────────────

  # ── demo:binding ───────────────────────────────────────────────────────────
  desc <<~DESC
    Account-binding walkthrough — a diner links their AI assistant to their
    restaurant account, and the assistant's booking then ties to that account.

    Runs demo:setup (clean DB + seed), boots the server, and runs binding_flow.rb,
    which drives BOTH sides of the ceremony over plain HTTP:

      1. The human diner (Diego) signs in through the REAL Devise form
         (/users/sign_in — cookie + CSRF dance) and mints a LINK code
         (POST /kiosk/auth/link, session channel — the human IS the approval).
      2. The assistant, with a FRESH key, redeems the code (POST /kiosk/auth/claim,
         key + possession proof) → a kiosk.agents row is bound to Diego's account.
      3. As that bound token, the assistant books a table for two tomorrow at 8.

    Asserts:
      • the diner signed in via the real Devise form
      • link-code mint (session channel) → 201
      • link-code redeem binds the assistant to the diner's account (user_id == Diego)
      • book_table as the bound token → 200, confirmed
      • the assistant's my_bookings shows the reservation
      • DB ground truth — the load-bearing assertion: bookings.user_id for the
        reservation == Diego's account id (book_table writes under
        kiosk.current_user_id(), which the binding set to the human)
      • DB ground truth: kiosk.agents.user_id for the assistant == Diego's account

    Exits 0 if every assertion holds; exits 1 on failure.
  DESC
  task binding: :setup do
    require "resolv"
    require "json"
    require "shellwords"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-binding.log"
    db   = "kiosk_atablefor_development"
    flow_rb = File.expand_path("../../binding_flow.rb", __dir__)
    failures = []

    # The seeded diner (db/seeds.rb) — Diego signs in and mints the link code.
    holder_id       = "00000000-0000-0000-0000-000000000001"
    holder_email    = "diego@example.com"
    holder_password = "atablefor-demo-password"

    host = begin
      addr = Resolv.getaddress("atablefor.app") rescue ""
      addr == "127.0.0.1" ? "atablefor.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (account-binding walkthrough) on #{server_url} ──"

    server_pid = spawn(
      { "KIOSK_ISSUER" => kiosk_issuer },
      "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
      out: log, err: log,
    )

    require "net/http"
    require "uri"
    begin
      ready = false
      30.times do
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

      puts "\n── Running binding_flow.rb ──"
      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape} " \
            "HOLDER_ID=#{holder_id.shellescape} HOLDER_EMAIL=#{holder_email.shellescape} " \
            "HOLDER_PASSWORD=#{holder_password.shellescape}"
      raw = `#{env} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      puts raw

      begin
        result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
      rescue JSON::ParserError => e
        abort "binding_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
      end

      puts "\n══ Account-binding assertions ══"
      check = lambda do |label, ok|
        if ok then puts "  ✓  #{label}" else failures << label; puts "  ✗  #{label}" end
      end
      check.call("diner signed in via the real Devise form",            result["human_signed_in"] == true)
      check.call("link-code mint (session channel) → 201",              result["link_mint"] == 201)
      check.call("link-code redeem → 201",                              result["link_claim"] == 201)
      check.call("redeem binds the assistant to the diner's account",   result["bound_to_holder"] == true)
      check.call("book_table as the bound token → 200",                 result["wire_book"] == 200)
      check.call("booking is confirmed",                                result["booking_status"] == "confirmed")
      check.call("assistant's my_bookings shows the reservation",       result["my_bookings_has_it"] == true)

      # ── DB ground truth (the load-bearing assertions) ──
      booking_id = result["booking_id"].to_s
      agent_id   = result["agent_id"].to_s
      booking_owner = `psql -X -d #{db} -tAc "SELECT user_id FROM bookings WHERE id = '#{booking_id}'" 2>&1`.strip
      check.call("DB bookings.user_id for the reservation == the diner (#{holder_id})", booking_owner == holder_id)
      agent_owner = `psql -X -d #{db} -tAc "SELECT user_id FROM kiosk.agents WHERE id = '#{agent_id}'" 2>&1`.strip
      check.call("DB kiosk.agents.user_id for the assistant == the diner", agent_owner == holder_id)
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All account-binding assertions PASSED — the assistant's booking ties to the diner's account."
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:binding ───────────────────────────────────────────────────────

  # ---------------------------------------------------------------------------
  desc <<~DESC
    Adversarial cross-tenant isolation test (table-booking domain).

    Boots the server, runs isolation_flow.rb with two fresh principals (A and B),
    and asserts all cross-tenant denial properties:

      HEADLINE (owner-scoped cancel): B cannot cancel_booking A's booking.
        A books table oA. B calls cancel_booking with booking_id=oA → MUST be
        403: cancel_booking gates on booking-ownership, so a cross-principal
        cancel is rejected and A's booking stays confirmed.
      Assertion 1 (exclusion): B's my_bookings does NOT contain A's booking oA.
      Assertion 2 (forged user_id ignored): B calls book_table with a forged
        user_id arg (A's UUID). The created booking belongs to B (server uses
        kiosk.current_user_id(), ignores agent-supplied user_id). Verified by:
          - the booking's DB user_id column == B's user_id (not A's)
          - B's my_bookings contains the booking
          - A's my_bookings does NOT contain it

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-isolation.log"

    host = begin
      addr = Resolv.getaddress("atablefor.app") rescue ""
      if addr == "127.0.0.1"
        "atablefor.app"
      else
        puts "  add to /etc/hosts:  127.0.0.1 atablefor.app" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (isolation test) on #{server_url} ──"

    env_vars = { "KIOSK_ISSUER" => kiosk_issuer }
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
    end

    require "net/http"
    require "uri"
    ready = false
    30.times do
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

    user_id_a             = result["user_id_a"]
    user_id_b             = result["user_id_b"]
    booking_id_a          = result["booking_id_a"]
    booking_id_b          = result["booking_id_b"]
    b_cancel_on_a_status  = result["b_cancel_on_a_status"]
    b_before              = result["b_booking_ids_before"] || []
    b_after               = result["b_booking_ids_after"]  || []
    a_after               = result["a_booking_ids_after"]  || []

    # ── HEADLINE: B cannot cancel A's booking (owner-scoped gate) ──
    if b_cancel_on_a_status == 403
      puts "  ✓  HEADLINE: B cannot cancel_booking on A's booking (owner-scoped gate) → 403"
    else
      failures << "ISOLATION HOLE: B's cancel_booking on A's booking returned #{b_cancel_on_a_status} (expected 403)"
      puts "  ✗  HEADLINE: cancel_booking ownership gate FAILED — returned #{b_cancel_on_a_status}"
    end

    # ── Assertion 1: B's my_bookings (before) excludes A's booking ────
    if b_before.include?(booking_id_a)
      failures << "ISOLATION HOLE: B's my_bookings (before) contains A's booking #{booking_id_a} — cross-tenant leak"
      puts "  ✗  Assertion 1 FAILED: B sees A's booking #{booking_id_a} — isolation hole"
    else
      puts "  ✓  Assertion 1: B's my_bookings (before) excludes A's booking #{booking_id_a} (app-layer isolation)"
    end

    # ── Assertion 2a: B's my_bookings (after forged booking) contains oB ──
    if b_after.include?(booking_id_b)
      puts "  ✓  Assertion 2a: B's my_bookings (after forged booking) includes oB #{booking_id_b}"
    else
      failures << "B's my_bookings (after forged booking) does not contain oB #{booking_id_b}; got #{b_after.inspect}"
      puts "  ✗  Assertion 2a FAILED: B's my_bookings missing oB #{booking_id_b}"
    end

    # ── Assertion 2b: A's my_bookings (after B's forged booking) excludes oB ──
    if a_after.include?(booking_id_b)
      failures << "ISOLATION HOLE: A's my_bookings contains B's forged booking #{booking_id_b} — cross-tenant leak"
      puts "  ✗  Assertion 2b FAILED: A sees B's booking #{booking_id_b} — isolation hole"
    else
      puts "  ✓  Assertion 2b: A's my_bookings excludes B's forged booking #{booking_id_b}"
    end

    # ── Assertion 2c: DB user_id on oB is B's, not A's (forged arg ignored) ──
    db = "kiosk_atablefor_development"
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM bookings WHERE id = '#{booking_id_b}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  ✓  Assertion 2c: DB bookings.user_id for oB == user_id_b (#{user_id_b}) — forged arg ignored"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB bookings.user_id for oB is A's user_id (#{user_id_a}) — forged user_id arg was NOT ignored"
      puts "  ✗  Assertion 2c FAILED: server used forged user_id arg (booking belongs to A, not B)"
    else
      failures << "Unexpected user_id for oB: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  ✗  Assertion 2c FAILED: unexpected user_id #{db_user_id.inspect} for oB"
    end

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer isolation holds."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end

  # ── demo:schema ──────────────────────────────────────────────────────────
  desc <<~DESC
    Self-discovery proof — verifies the schema verb AND the pay-absent capability set.

    Boots the server, runs schema_flow.rb (GET /kiosk/schema + /.well-known/kiosk.json
    + /agents.json + /agents.txt).

    Asserts:
      • discovery capabilities == [schema, query, run] and do NOT include `pay`
        (atablefor takes no payments — a reservation needs none)
      • agents.json carries NO payments block; agents.txt has no ap2 / Payments
      • schema.queries includes availability + my_bookings with descriptions
      • schema.actions includes book_table + cancel_booking with descriptions

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-schema.log"

    host = begin
      addr = Resolv.getaddress("atablefor.app") rescue ""
      addr == "127.0.0.1" ? "atablefor.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (schema proof) on #{server_url} ──"

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
    end

    ready = false
    30.times do
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

    verbs        = result["schema_verbs"]          || []
    queries      = result["schema_queries"]        || []
    actions      = result["schema_actions"]        || []
    capabilities = result["discovery_capabilities"] || []

    # ── NOT-ONLY-COMMERCE: pay absent from the ADVERTISED capability set ──
    if capabilities.include?("pay")
      failures << "discovery capabilities advertise `pay` (got #{capabilities.inspect}) — atablefor takes no payments"
      puts "  ✗  discovery capabilities include `pay` — must be ABSENT"
    else
      puts "  ✓  discovery capabilities do NOT include `pay` (#{capabilities.inspect}) — a reservation needs no payment"
    end
    %w[schema query run].each do |cap|
      if capabilities.include?(cap)
        puts "  ✓  discovery capabilities include #{cap}"
      else
        failures << "discovery capabilities missing #{cap} (got #{capabilities.inspect})"
        puts "  ✗  discovery capabilities missing #{cap}"
      end
    end

    # agents.json / agents.txt carry no payments surface
    if result["agents_json_has_payments"]
      failures << "agents.json carries a payments block — must be absent"
      puts "  ✗  agents.json has a payments block"
    else
      puts "  ✓  agents.json carries NO payments block"
    end
    if result["agents_txt_has_ap2"] || result["agents_txt_has_payments"]
      failures << "agents.txt advertises ap2 / Payments — must be absent"
      puts "  ✗  agents.txt advertises ap2 / Payments"
    else
      puts "  ✓  agents.txt carries no ap2 / Payments directives"
    end

    # Queries: availability, my_bookings with descriptions
    %w[availability my_bookings].each do |qname|
      entry = queries.find { |q| q["name"] == qname }
      if entry && entry["description"] && !entry["description"].to_s.empty?
        puts "  ✓  schema.queries includes #{qname} with a description"
      else
        failures << "schema.queries missing #{qname} (or its description)"
        puts "  ✗  schema.queries missing #{qname} (or its description)"
      end
    end

    # Actions: book_table, cancel_booking with descriptions
    %w[book_table cancel_booking].each do |aname|
      entry = actions.find { |a| a["name"] == aname }
      if entry && entry["description"] && !entry["description"].to_s.empty?
        puts "  ✓  schema.actions includes #{aname} with a description"
      else
        failures << "schema.actions missing #{aname} (or its description)"
        puts "  ✗  schema.actions missing #{aname} (or its description)"
      end
    end

    # T-042 / K-452: the primary read query (availability) and primary action
    # (book_table) advertise the machine-readable descriptor extensions.
    {
      queries => %w[availability],
      actions => %w[book_table],
    }.each do |list, names|
      names.each do |dname|
        entry = list.find { |e| e["name"] == dname } || {}
        %w[input_schema example_params example_row].each do |ext|
          if entry.key?(ext) && !entry[ext].nil?
            puts "  ✓  #{dname} advertises #{ext}"
          else
            failures << "#{dname} missing #{ext}"
            puts "  ✗  #{dname} missing #{ext}"
          end
        end
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
  # ── end demo:schema ───────────────────────────────────────────────────────

  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery.

    Boots atablefor, runs redteam_suite.rb and asserts each applicable attack is
    BLOCKED:

      BLOCKED  CrossTenantRead    — B's my_bookings must not include A's booking
      BLOCKED  ForgedUserId       — agent-supplied user_id arg ignored on book_table
      BLOCKED  CrossOwnerCancel   — B cancel_booking on A's booking → 403
      BLOCKED  RegisterWithoutPoP — register without a signed PoP → not 201
      BLOCKED  MissingAuth        — no Authorization → 401
      BLOCKED  GarbageToken       — unparseable bearer → 401
      BLOCKED  UnknownQuery       — unregistered query name → 404
      BLOCKED  UnknownAction      — unregistered action name → 404

    Exits 0 when all scenarios are BLOCKED (0 BREACH); exits 1 on any BREACH.
    A BREACH = a real hole in atablefor — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-redteam.log"

    host = begin
      addr = Resolv.getaddress("atablefor.app") rescue ""
      addr == "127.0.0.1" ? "atablefor.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (redteam battery) on #{server_url} ──"

    env_vars = { "KIOSK_ISSUER" => kiosk_issuer }

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
    end

    ready = false
    30.times do
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

desc "End-to-end Kiosk demo: setup the DB then run the no-human table booking end-to-end."
task demo: ["demo:setup", "demo:book"]
