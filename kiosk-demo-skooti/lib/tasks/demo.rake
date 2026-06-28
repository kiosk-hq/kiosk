# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-skooti (Arch 2 — Ed25519 offline token).
# Tasks:
#
#   rake demo:setup      idempotent db:drop / create / migrate / seed
#   rake demo:rideflow   boots the server, runs rental_flow.rb (no-human full
#                        rental chain), asserts happy path + all negative gates,
#                        tears down
#   rake demo            setup + rideflow (full end-to-end proof)
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

  desc "Boot the server, run rental_flow.rb end-to-end (happy + all negative gates), assert."
  task :rideflow do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"
    require "openssl"
    require "base64"

    $LOAD_PATH.unshift File.expand_path("../", __dir__)
    require "lock_sim"
    require "dev_unlock_key"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-skooti-demo.log"

    # ── host resolution ────────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("skooti.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "skooti.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 skooti.app — using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_skooti_development"
    flow_rb      = File.expand_path("../../rental_flow.rb", __dir__)

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

    # Helper: run rental_flow.rb with the given env vars; return parsed JSON result.
    run_flow = lambda do |extra_env = {}|
      env = {
        "SERVER_URL"   => server_url,
        "KIOSK_ISSUER" => kiosk_issuer,
      }.merge(extra_env)
      env_str = env.map { |k, v| "#{k}=#{v.to_s.shellescape}" }.join(" ")
      raw = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      json_line   = raw.lines.grep(/^\{/).last
      stderr_lines = raw.lines.reject { |l| l.start_with?("{") }
      puts stderr_lines.join
      puts json_line if json_line

      begin
        JSON.parse(json_line || raw)
      rescue JSON::ParserError => e
        abort "rental_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
      end
    end

    # ── RUN 1: Happy path ─────────────────────────────────────────────────
    puts "\n══ RUN 1: Happy path ══"
    happy_result = nil
    boot_server.call do
      happy_result = run_flow.call

      # ── Basic HTTP + lock assertions ────────────────────────────────────
      if happy_result["http_browse"] == 200
        puts "  OK  http_browse (query scooters_available) == 200"
      else
        failures << "happy: http_browse expected 200, got #{happy_result["http_browse"].inspect}"
        puts "  FAIL  http_browse expected 200, got #{happy_result["http_browse"].inspect}"
      end

      browse_count = happy_result["browse_rows_count"].to_i
      if browse_count >= 1
        puts "  OK  browse_rows_count >= 1 (got #{browse_count})"
      else
        failures << "happy: browse_rows_count expected >= 1, got #{browse_count.inspect}"
        puts "  FAIL  browse_rows_count expected >= 1, got #{browse_count.inspect}"
      end

      if happy_result["http_start_rental"] == 200
        puts "  OK  http_start_rental == 200"
      else
        failures << "happy: http_start_rental expected 200, got #{happy_result["http_start_rental"].inspect}"
        puts "  FAIL  http_start_rental expected 200, got #{happy_result["http_start_rental"].inspect}"
      end

      if happy_result["unlocked"] == true
        puts "  OK  unlocked == true"
      else
        failures << "happy: unlocked expected true, got #{happy_result["unlocked"].inspect}"
        puts "  FAIL  unlocked — got #{happy_result["unlocked"].inspect}"
      end

      rental_token = happy_result["rental_token"]
      if rental_token && !rental_token.empty?
        puts "  OK  rental_token present (#{rental_token[0, 30]}...)"
      else
        failures << "happy: rental_token missing or empty"
        puts "  FAIL  rental_token missing or empty"
      end

      exp = happy_result["exp"]
      if exp && exp.to_i > 0
        puts "  OK  exp present (#{exp})"
      else
        failures << "happy: exp missing or zero"
        puts "  FAIL  exp missing or zero"
      end

      # ── psql assertions ────────────────────────────────────────────────
      res_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM public.reservations WHERE status='active'" 2>&1`.strip
      if res_count.to_i >= 1
        puts "  OK  reservations[status=active] >= 1 (got #{res_count})"
      else
        failures << "happy: reservations[status=active] expected >= 1, got #{res_count.inspect}"
        puts "  FAIL  reservations[status=active] expected >= 1, got #{res_count.inspect}"
      end

      pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates' 2>&1`.strip
      if pm_count.to_i >= 1
        puts "  OK  kiosk.payment_mandates >= 1 (got #{pm_count})"
      else
        failures << "happy: kiosk.payment_mandates expected >= 1, got #{pm_count.inspect}"
        puts "  FAIL  kiosk.payment_mandates expected >= 1, got #{pm_count.inspect}"
      end

      # ── Offline-token negatives (lock-sim level) ─────────────────────────
      # These run purely in Ruby — no server round-trip needed.
      if rental_token && !rental_token.empty?
        puts "\n  -- Offline-token negatives --"

        pub_pem    = DevUnlockKey.public_key_pem
        skooti_pub = OpenSSL::PKey.read(pub_pem)

        sc  = happy_result.fetch("rental_token") && begin
          # Extract scooter_code from the token message (field 1 in v2; field 0 is the context tag).
          msg = rental_token.split(".").tap { |p| p.pop }.join(".")
          msg.split("|")[1]
        end
        exp_val = happy_result["exp"].to_i

        # N1: expired — call unlock with now = exp + 1
        lock_n1  = LockSim.new(scooter_code: sc, skooti_public_key: skooti_pub)
        result_n1 = lock_n1.unlock(token: rental_token, now: exp_val + 1)
        if result_n1 == false
          puts "  OK  N1 expired: unlock(now=exp+1) == false"
        else
          failures << "offline-neg: N1 expired expected false, got #{result_n1.inspect}"
          puts "  FAIL  N1 expired: expected false, got #{result_n1.inspect}"
        end

        # N2: wrong scooter — same token, different scooter_code provisioned
        lock_n2  = LockSim.new(scooter_code: "SK-999", skooti_public_key: skooti_pub)
        result_n2 = lock_n2.unlock(token: rental_token, now: Time.now.to_i)
        if result_n2 == false
          puts "  OK  N2 wrong-scooter: unlock(SK-999) == false"
        else
          failures << "offline-neg: N2 wrong-scooter expected false, got #{result_n2.inspect}"
          puts "  FAIL  N2 wrong-scooter: expected false, got #{result_n2.inspect}"
        end

        # N3: forged sig — flip the last character of the sig portion
        dot_idx    = rental_token.rindex(".")
        msg_part   = rental_token[0...dot_idx]
        sig_part   = rental_token[(dot_idx + 1)..]
        last_char  = sig_part[-1]
        # Flip between 'A' and 'B' so the base64url decode always produces 64 bytes
        flipped    = last_char == "A" ? "B" : "A"
        forged_token = "#{msg_part}.#{sig_part[0..-2]}#{flipped}"
        lock_n3    = LockSim.new(scooter_code: sc, skooti_public_key: skooti_pub)
        result_n3  = lock_n3.unlock(token: forged_token, now: Time.now.to_i)
        if result_n3 == false
          puts "  OK  N3 forged-sig: unlock(flipped sig) == false"
        else
          failures << "offline-neg: N3 forged-sig expected false, got #{result_n3.inspect}"
          puts "  FAIL  N3 forged-sig: expected false, got #{result_n3.inspect}"
        end

        # N4: replay jti — unlock the same token twice (second must be false)
        lock_n4    = LockSim.new(scooter_code: sc, skooti_public_key: skooti_pub)
        first_try  = lock_n4.unlock(token: rental_token, now: Time.now.to_i)
        second_try = lock_n4.unlock(token: rental_token, now: Time.now.to_i)
        if first_try == true && second_try == false
          puts "  OK  N4 replay-jti: first=true, second=false"
        else
          failures << "offline-neg: N4 replay expected first=true/second=false, got first=#{first_try.inspect}/second=#{second_try.inspect}"
          puts "  FAIL  N4 replay-jti: expected first=true/second=false, got first=#{first_try.inspect}/second=#{second_try.inspect}"
        end
      end
    end

    # ── RUN 2: Server-gate negative — SKIP_PAY → 403 ─────────────────────
    puts "\n══ RUN 2: Server-gate negative — SKIP_PAY → 403 ══"
    boot_server.call do
      result = run_flow.call("SKIP_PAY" => "1")

      if result["http_start_rental"] == 403
        puts "  OK  SKIP_PAY: http_start_rental == 403"
      else
        failures << "skip_pay: http_start_rental expected 403, got #{result["http_start_rental"].inspect}"
        puts "  FAIL  SKIP_PAY: expected 403, got #{result["http_start_rental"].inspect}"
      end
    end

    # ── RUN 3: Server-gate negative — SKIP_KYC → 403 ─────────────────────
    puts "\n══ RUN 3: Server-gate negative — SKIP_KYC → 403 ══"
    boot_server.call do
      result = run_flow.call("SKIP_KYC" => "1")

      if result["http_start_rental"] == 403
        puts "  OK  SKIP_KYC: http_start_rental == 403"
      else
        failures << "skip_kyc: http_start_rental expected 403, got #{result["http_start_rental"].inspect}"
        puts "  FAIL  SKIP_KYC: expected 403, got #{result["http_start_rental"].inspect}"
      end
    end

    # ── RUN 4: C2 — unpaid second reservation → 403 ───────────────────────
    # A fresh reservation with no payment — Gate 3 must reject.
    puts "\n══ RUN 4: C2 — unpaid second reservation → 403 ══"
    boot_server.call do
      result = run_flow.call("SKIP_PAY" => "1")

      if result["http_start_rental"] == 403
        puts "  OK  C2 unpaid-reservation: http_start_rental == 403"
      else
        failures << "c2_unpaid: http_start_rental expected 403, got #{result["http_start_rental"].inspect}"
        puts "  FAIL  C2 unpaid-reservation: expected 403, got #{result["http_start_rental"].inspect}"
      end
    end

    # ── RUN 5: C3 — re-start_rental on already-active reservation → 403 ───
    # Happy run makes the reservation active; second start_rental must fail.
    puts "\n══ RUN 5: C3 — re-start_rental on active reservation → 403 ══"
    boot_server.call do
      # First run: full happy path to make the reservation active.
      inner = run_flow.call
      unless inner["http_start_rental"] == 200
        abort "C3 inner happy run unexpectedly failed: http_start_rental=#{inner["http_start_rental"]}"
      end
      active_reservation_id = inner["reservation_id"]
      puts "  Active reservation: #{active_reservation_id}"

      # Second run: fresh agent (new register+KYC+pay) but REUSE_RESERVATION
      # so no new reserve; status='active' → Gate 1 rejects with 403.
      # We use a separate script invocation so the agent token is fresh.
      # We pass REUSE_RESERVATION which rental_flow.rb does NOT support natively —
      # so instead we implement this directly here (no second flow invocation needed):
      # just call start_rental again with the same reservation_id using a NEW agent.
      #
      # Simpler: call the server directly in this Rake task.
      require "digest"
      require "net/http"
      require "openssl"
      require "securerandom"

      # Re-register a fresh agent.
      agent_key     = OpenSSL::PKey::RSA.generate(2048)
      agent_pem     = agent_key.public_key.to_pem
      difficulty    = 20

      pow = 0
      pow += 1 until begin
        d = Digest::SHA256.digest("#{agent_pem}.#{pow}")
        count = 0
        d.each_byte do |b|
          if b == 0; count += 8
          else; bit = 7; bit -= 1 while bit >= 0 && b[bit] == 0; count += (7 - bit); break
          end
        end
        count >= difficulty
      end

      uri = URI("#{server_url}/kiosk/agents/register")
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      req.body = JSON.generate(name: "hermes-c3", public_key: agent_pem, role: "customer", pow: pow.to_s)
      reg_resp = Net::HTTP.new(uri.host, uri.port).request(req)
      reg_data = JSON.parse(reg_resp.body)
      agent_token = reg_data["access_token"]
      new_user_id = reg_data["user_id"]

      # KYC the new agent.
      require_relative "../../lib/stub_kyc"
      att = StubKyc.attest(user_id: new_user_id)
      kyc_uri = URI("#{server_url}/kiosk/agents/kyc")
      kyc_req = Net::HTTP::Post.new(kyc_uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{agent_token}")
      kyc_req.body = JSON.generate(kyc_jws: att)
      Net::HTTP.new(kyc_uri.host, kyc_uri.port).request(kyc_req)

      # Attempt start_rental on the ALREADY ACTIVE reservation — Gate 1 rejects.
      exec_uri = URI("#{server_url}/kiosk/exec")
      exec_req = Net::HTTP::Post.new(exec_uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{agent_token}")
      exec_req.body = JSON.generate(command: "run", body: { name: "start_rental", reservation_id: active_reservation_id })
      exec_res = Net::HTTP.new(exec_uri.host, exec_uri.port).request(exec_req)
      rc_c3 = exec_res.code.to_i

      if rc_c3 == 403
        puts "  OK  C3 re-start_rental: http == 403 (reservation already active)"
      else
        failures << "c3_relock: http_start_rental expected 403, got #{rc_c3.inspect}"
        puts "  FAIL  C3 re-start_rental: expected 403, got #{rc_c3.inspect}"
        puts "       Response: #{exec_res.body}"
      end
    end

    # ── RUN 6: Query-verb assertions — scooters_available + per-user my_reservations ──
    # Proves: (a) query scooters_available returns SK-001;
    #         (b) query my_reservations after reserve returns exactly the
    #             principal's reservation (app-layer per-user isolation, no RLS).
    puts "\n══ RUN 6: Query-verb assertions (scooters_available + my_reservations per-user) ══"
    boot_server.call do
      require "digest"
      require "net/http"
      require "openssl"
      require "securerandom"

      # Helper: one POST and return [status_int, parsed_body].
      q_post = lambda do |path, body_hash, bearer|
        uri = URI("#{server_url}#{path}")
        req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{bearer}")
        req.body = JSON.generate(body_hash)
        res = Net::HTTP.new(uri.host, uri.port).request(req)
        [res.code.to_i, JSON.parse(res.body)]
      end

      # Register a fresh agent (re-use PoW solve helper from RUN 5 pattern).
      q_key = OpenSSL::PKey::RSA.generate(2048)
      q_pem = q_key.public_key.to_pem
      q_pow = 0
      q_pow += 1 until begin
        d = Digest::SHA256.digest("#{q_pem}.#{q_pow}")
        count = 0
        d.each_byte do |b|
          if b == 0; count += 8
          else; bit = 7; bit -= 1 while bit >= 0 && b[bit] == 0; count += (7 - bit); break
          end
        end
        count >= 20
      end
      reg_rc, reg_data = q_post.call(
        "/kiosk/agents/register",
        { name: "hermes-q6", public_key: q_pem, role: "customer", pow: q_pow.to_s },
        "",
      )
      abort "RUN6 register failed (#{reg_rc})" unless reg_rc == 201
      q_token   = reg_data["access_token"]
      q_user_id = reg_data["user_id"]

      # KYC the agent.
      require_relative "../../lib/stub_kyc"
      q_att = StubKyc.attest(user_id: q_user_id)
      q_post.call("/kiosk/agents/kyc", { kyc_jws: q_att }, q_token)

      # ── QA1: query scooters_available — SK-001 must be present ──────────
      qa1_rc, qa1_resp = q_post.call(
        "/kiosk/exec",
        { command: "query", body: { name: "scooters_available" } },
        q_token,
      )
      if qa1_rc == 200
        rows = qa1_resp["rows"] || []
        codes = rows.map { |r| r["code"] }
        if codes.include?("SK-001")
          puts "  OK  QA1 scooters_available: SK-001 present (#{codes.inspect})"
        else
          failures << "qa1: scooters_available — SK-001 not found, got #{codes.inspect}"
          puts "  FAIL  QA1 scooters_available: SK-001 not found, got #{codes.inspect}"
        end
      else
        failures << "qa1: query scooters_available expected 200, got #{qa1_rc}"
        puts "  FAIL  QA1 query scooters_available returned #{qa1_rc}: #{qa1_resp.inspect}"
      end

      # ── QA2: query my_reservations before reservation — must be empty ────
      qa2_rc, qa2_resp = q_post.call(
        "/kiosk/exec",
        { command: "query", body: { name: "my_reservations" } },
        q_token,
      )
      if qa2_rc == 200
        rows_before = qa2_resp["rows"] || []
        if rows_before.empty?
          puts "  OK  QA2 my_reservations (before reserve): empty for fresh principal"
        else
          failures << "qa2: my_reservations before reserve expected [], got #{rows_before.inspect}"
          puts "  FAIL  QA2 my_reservations before reserve: expected [], got #{rows_before.inspect}"
        end
      else
        failures << "qa2: query my_reservations expected 200, got #{qa2_rc}"
        puts "  FAIL  QA2 query my_reservations returned #{qa2_rc}: #{qa2_resp.inspect}"
      end

      # Reserve SK-001 for this principal.
      rsv_rc, rsv_data = q_post.call(
        "/kiosk/exec",
        { command: "run", body: { name: "reserve", scooter_code: "SK-001" } },
        q_token,
      )
      abort "RUN6 reserve failed (#{rsv_rc}): #{rsv_data.inspect}" unless rsv_rc == 200
      q_reservation_id = rsv_data.dig("value", "reservation_id")
      puts "  Reserved: #{q_reservation_id}"

      # ── QA3: query my_reservations after reservation — exactly 1 row ─────
      # Demonstrates app-layer per-user isolation: only this principal's
      # reservation is visible; not rows from other principals (RUN 1 etc.).
      qa3_rc, qa3_resp = q_post.call(
        "/kiosk/exec",
        { command: "query", body: { name: "my_reservations" } },
        q_token,
      )
      if qa3_rc == 200
        rows_after = qa3_resp["rows"] || []
        if rows_after.size == 1 && rows_after.first["id"] == q_reservation_id
          puts "  OK  QA3 my_reservations (after reserve): exactly 1 row, id matches"
        else
          failures << "qa3: my_reservations expected [{id:#{q_reservation_id}}], got #{rows_after.inspect}"
          puts "  FAIL  QA3 my_reservations after reserve: expected 1 row with id=#{q_reservation_id}, got #{rows_after.inspect}"
        end
      else
        failures << "qa3: query my_reservations expected 200, got #{qa3_rc}"
        puts "  FAIL  QA3 query my_reservations returned #{qa3_rc}: #{qa3_resp.inspect}"
      end
    end

    # ── RLS gone: confirm structure.sql has no ROW LEVEL SECURITY for app tables ──
    puts "\n══ Structure check: no ROW LEVEL SECURITY on scooters/reservations ══"
    structure_path = File.expand_path("../../db/structure.sql", __dir__)
    if File.exist?(structure_path)
      structure = File.read(structure_path)
      if structure.match?(/ROW LEVEL SECURITY/)
        failures << "structure.sql still contains ROW LEVEL SECURITY — regenerate after migration edit"
        puts "  FAIL  structure.sql still contains ROW LEVEL SECURITY"
      else
        puts "  OK  structure.sql: no ROW LEVEL SECURITY found"
      end
    else
      puts "  (structure.sql not found — skip RLS check)"
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
  # ---------------------------------------------------------------------------
  desc <<~DESC
    Adversarial cross-tenant isolation test (R1 Phase 1 Task 2).

    Runs demo:setup (clean DB + seed), boots the server, runs isolation_flow.rb
    with two fresh principals (A and B), and asserts all cross-tenant denial properties:

      Assertion 1 (ownership denial — Gate-1 isolated): B satisfies Gate-2 (KYC)
        and Gate-3 (settles a payment mandate referencing rA) then calls
        start_rental on A's reservation_id. Gate-1 (user_id = kiosk.current_user_id()
        AND status='reserved') finds nothing → 403. The 403 isolates Gate-1 ownership
        because Gate-2 and Gate-3 are both genuinely satisfied by B.
      Assertion 2a (exclusion): B's my_reservations does NOT contain A's reservation.
      Assertion 2b (positive control): B's my_reservations DOES contain B's own
        reservation, proving the exclusion is not vacuous.
      Assertion 3 (forged user_id ignored): B calls reserve with user_id: A's UUID.
        The created reservation's DB user_id is B (server uses kiosk.current_user_id(),
        ignores agent-supplied user_id).

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-skooti-isolation.log"

    # ── host resolution ────────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("skooti.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "skooti.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 skooti.app — using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_skooti_development"

    puts "\n── Starting skooti (isolation test) on #{server_url} ──"

    # ── boot the server ────────────────────────────────────────────────────
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

    # ── wait for readiness ─────────────────────────────────────────────────
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

    # ── run isolation_flow.rb ──────────────────────────────────────────────
    flow_rb = File.expand_path("../../isolation_flow.rb", __dir__)
    puts "\n── Running isolation_flow.rb (adversarial cross-tenant) ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "isolation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_a               = result["user_id_a"]
    user_id_b               = result["user_id_b"]
    reservation_id_a        = result["reservation_id_a"]
    reservation_id_b_forged = result["reservation_id_b_forged"]
    b_start_rental_rc       = result["b_start_rental_rc"]
    b_reservation_ids       = result["b_reservation_ids"] || []

    # ── Assertion 1: B's start_rental on A's reservation → 403 ──────────
    # B passed Gate-2 (KYC) and Gate-3 (payment for rA) before this attempt;
    # the 403 therefore isolates Gate-1 ownership exclusively.
    if b_start_rental_rc == 403
      puts "  OK  Assertion 1: B's start_rental on A's rA #{reservation_id_a} → 403 (Gate-1 ownership denied; Gate-2+3 passed)"
    else
      failures << "ISOLATION HOLE: B's start_rental on A's reservation returned #{b_start_rental_rc.inspect} (expected 403) — Gate-1 ownership bypass"
      puts "  FAIL  Assertion 1: B's start_rental on A's rA expected 403, got #{b_start_rental_rc.inspect} — isolation hole"
    end

    # ── Assertion 2a: B's my_reservations excludes A's reservation ───────
    if b_reservation_ids.include?(reservation_id_a)
      failures << "ISOLATION HOLE: B's my_reservations contains A's reservation #{reservation_id_a} — cross-tenant leak"
      puts "  FAIL  Assertion 2a: B sees A's reservation #{reservation_id_a} in my_reservations — isolation hole"
    else
      puts "  OK  Assertion 2a: B's my_reservations excludes A's reservation #{reservation_id_a} (app-layer isolation)"
    end

    # ── Assertion 2b: B's my_reservations includes B's own reservation ───
    # Positive control: proves the exclusion above is not vacuous (the query
    # returns rows for B; if it always returned empty, Assertion 2a would
    # pass spuriously).
    if b_reservation_ids.include?(reservation_id_b_forged)
      puts "  OK  Assertion 2b: B's my_reservations includes B's own #{reservation_id_b_forged} (positive control — exclusion non-vacuous)"
    else
      failures << "B's my_reservations does not include B's own reservation #{reservation_id_b_forged}; got #{b_reservation_ids.inspect} — positive control failed (vacuous exclusion)"
      puts "  FAIL  Assertion 2b: B's my_reservations missing B's own rB_forged #{reservation_id_b_forged} — positive control failed"
    end

    # ── Assertion 3: DB user_id on B's forged reservation == user_id_b ───
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM public.reservations WHERE id = '#{reservation_id_b_forged}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  OK  Assertion 3: DB reservations.user_id for rB == user_id_b (#{user_id_b}) — forged arg ignored"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB reservations.user_id for rB is A's user_id (#{user_id_a}) — forged user_id arg was NOT ignored"
      puts "  FAIL  Assertion 3: server used forged user_id arg (reservation belongs to A, not B)"
    else
      failures << "Unexpected user_id for rB: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  FAIL  Assertion 3: unexpected user_id #{db_user_id.inspect} for rB"
    end

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer isolation holds."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
end

namespace :demo do
  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery (R3 Phase 2 Task 4) — kiosk-redteam.

    Boots skooti, runs all 12 Kiosk::Redteam scenarios against the full chain
    (PoW d=20 → KYC → reserve → pay → start_rental) and asserts each attack
    is BLOCKED:

      BLOCKED  PayForOtherUseSelf    — C2: B pays for A's reservation, tries start_rental
      BLOCKED  SpentResourceReuse    — C3: re-start_rental on already-active reservation
      BLOCKED  MissingKyc            — start_rental without any KYC → Gate-2 fires
      BLOCKED  ExpiredKyc            — expired attestation rejected at /kyc or Gate-2
      BLOCKED  ForgedKyc             — wrong-key attestation rejected at /kyc
      BLOCKED  UnpaidGatedAction     — start_rental without payment → Gate-3 fires
      BLOCKED  CrossTenantRead       — B's my_reservations excludes A's rows
      BLOCKED  ForgedUserId          — agent-supplied user_id in reserve args ignored
      BLOCKED  RegistrationWithoutPow — /register without PoW rejected (d=20)
      BLOCKED  MandatePrincipalSwap  — B signs mandate with A's identity; rejected
      BLOCKED  MandateReplay         — B re-submits A's JWS; rejected
      BLOCKED  TokenTampering        — altered JWT claim rejected 401

    Exits 0 when all scenarios are BLOCKED; exits 1 on any BREACH.
    A BREACH = a real hole in skooti — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-skooti-redteam.log"

    # ── host resolution ────────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("skooti.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "skooti.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 skooti.app — using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting skooti (redteam battery) on #{server_url} ──"

    # ── boot the server ────────────────────────────────────────────────────
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

    # ── wait for readiness ─────────────────────────────────────────────────
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

    # ── run redteam_suite.rb ───────────────────────────────────────────────
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

desc "End-to-end Kiosk skooti demo: setup the DB then prove the full rental chain (Arch 2)."
task demo: ["demo:setup", "demo:rideflow"]
