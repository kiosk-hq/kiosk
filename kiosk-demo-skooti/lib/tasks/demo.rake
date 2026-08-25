# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-skooti (Ed25519 offline token).
# Tasks:
#
#   rake demo:setup      idempotent db:drop / create / schema:load / seed
#   rake demo:kat        DB-free known-answer test for the RentalTokenIssuer
#                        demo lib (byte-exact wire vector the firmware mirrors)
#   rake demo:rideflow   boots the server, runs script/rental_flow.rb (no-human full
#                        rental chain), asserts happy path + all negative gates,
#                        tears down, then runs script/pay_window.rb in-process
#                        (K-853 capture-anchored paid state)
#   rake demo:isolation  adversarial cross-tenant + ownership isolation test
#   rake demo:kyc        named-anonymized-attribute KYC gate proof (age_over_18 +
#                        licence_a): motorcycle 403→attest→200, scooter stays KYC-free
#   rake demo:redteam    adversarial regression battery (kiosk-redteam scenarios)
#   rake demo:schema     self-discovery proof over the schema verb
#   rake demo            setup + rideflow (full end-to-end proof)

namespace :demo do
  desc "Known-answer test for the RentalTokenIssuer demo lib (DB-free; no server boot)."
  task :kat do
    # Run standalone (fresh ruby, no Rails): the KAT stands up its own tiny
    # Kiosk.configuration carrier and self-configures its load path, so it must
    # NOT be required into the booted Rails process (where the real
    # Kiosk::Configuration is present). Exit status propagates the pass/fail.
    sh "ruby #{Rails.root.join('script/rental_token_issuer_kat.rb')}"
  end

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

  desc "Boot the server, run script/rental_flow.rb end-to-end (happy + all negative gates), then the " \
       "in-process capture-window regression (script/pay_window.rb, K-853), assert."
  task :rideflow do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"
    require "openssl"
    require "base64"
    require "jwt"
    require "securerandom"
    require "shellwords"

    $LOAD_PATH.unshift File.expand_path("../", __dir__)
    # script/, not lib/ (K-861): both are flow-only helpers and moved out of
    # the app's eager-load set. A BARE `require` used to resolve them off the
    # load path Rails happens to set up for lib/, which is the implicit
    # dependency K-856 broke by moving a sibling file.
    require_relative "../../script/lock_sim"
    require_relative "../../script/dev_unlock_key"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-skooti-demo.log"

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
        Resolv.getaddress("skooti.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "skooti.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 skooti.demo.kiosk.tech — using 127.0.0.1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_skooti_development"
    flow_rb      = File.expand_path("../../script/rental_flow.rb", __dir__)

    failures = []

    # This task attests agents with ProveTestIssuer (the ProveKey), so the
    # server must be told to TRUST that key explicitly — skooti no longer
    # ships a pinned dev ProveKey (K-650).
    require_relative "../../script/prove_test_issuer"

    # Registration goes through the SHIPPED helper (K-696), never a local copy:
    # script/equihash_register.rb owns the challenge → PoP → 402 → solve → retry
    # handshake and asks Kiosk::Pow::Equihash.solver_path where solve.py lives,
    # so the gem that packages the solver stays the only thing that knows its
    # location (K-627/K-632). The two hand-rolled copies this replaces named
    # ../../../kiosk-pow-equihash/solve.py — a path that resolves in a monorepo
    # checkout and nowhere else — and were weaker than the helper besides: one
    # NoMethodError'd on any 402 whose body carried no error.challenges, and one
    # read access_token with no status assertion at all, so a failed register
    # yielded `Bearer ` and the 403 that earned was reported as the expected 403.
    require_relative "../../script/equihash_register"

    # The transport slots the helper takes: ->(url) and ->(url, body, headers = {}),
    # each returning [status, parsed_body]. The header slot carries Kiosk-PoW on
    # the retry (ADR-0022).
    reg_get = lambda do |url, headers = {}|
      uri = URI(url)
      res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
      [res.code.to_i, (JSON.parse(res.body) rescue {})]
    end
    reg_post = lambda do |url, body, headers = {}|
      uri = URI(url)
      req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
      req.body = JSON.generate(body)
      res = Net::HTTP.new(uri.host, uri.port).request(req)
      [res.code.to_i, (JSON.parse(res.body) rescue {})]
    end

    # Helper: spawn the server, wait for readiness, yield, then kill.
    boot_server = lambda do |&blk|
      File.truncate(log, 0) if File.exist?(log)
      server_pid = spawn(
        { "KIOSK_ISSUER"               => kiosk_issuer,
          "KIOSK_PROVE_PUBLIC_KEY_PEM" => ProveTestIssuer.public_key_pem },
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

    # Helper: run script/rental_flow.rb with the given env vars; return parsed JSON result.
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
        abort "script/rental_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
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
      #
      # BY ID, NOT BY DB-WIDE COUNT (K-862). `COUNT(*) >= 1` over the whole
      # table passes on a row a PREVIOUS run left behind, so the beat under
      # test could stop writing and both assertions would stay green. The
      # driver already reports the two anchors: this run's `reservation_id`
      # and the `user_id` of the agent it just registered.
      this_reservation = happy_result["reservation_id"]
      res_status = `psql -X -d #{db} -tAc "SELECT status FROM public.reservations WHERE id = '#{this_reservation}'" 2>&1`.strip
      if res_status == "active"
        puts "  OK  this run's reservation is active in the DB (id=#{this_reservation})"
      else
        failures << "happy: reservations[id=#{this_reservation}].status expected 'active', got #{res_status.inspect}"
        puts "  FAIL  reservations[id=#{this_reservation}].status — got #{res_status.inspect}"
      end

      # Settlements carry no reservation_id, so the anchor is the principal:
      # a fresh agent registers every run, so EXACTLY ONE settlement must
      # exist under this run's user_id (one pay, one receipt).
      this_user = happy_result["user_id"]
      pm_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM kiosk.settlements WHERE user_id = '#{this_user}'" 2>&1`.strip
      if pm_count.to_i == 1
        puts "  OK  exactly one kiosk.settlements row for this run's principal (#{this_user})"
      else
        failures << "happy: kiosk.settlements for user_id=#{this_user} expected 1, got #{pm_count.inspect}"
        puts "  FAIL  kiosk.settlements for this run's principal — got #{pm_count.inspect}"
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

    # RUN 5 (C3 — re-start_rental on an already-active reservation) was
    # removed here (K-697): it minted a NEW principal each time and called
    # start_rental on the INNER run's own reservation, so Gate 1's ownership
    # predicate (`user_id = kiosk.current_user_id()`) alone emptied the row
    # set — deleting the `status = 'reserved'` clause it claimed to cover
    # left it green (verified). Its KYC round-trips also discarded their
    # responses (a 4xx KYC failure was invisible) and gated nothing, and
    # register's response was checked only for `== 402`, so a failed
    # register could report a `Bearer ` 403 as a pass. The property it
    # claimed — a spent/active resource cannot be re-activated by the SAME
    # principal — is covered soundly by demo:redteam's
    # Kiosk::Redteam::Scenarios::SpentResourceReuse (script/redteam_suite.rb),
    # which drives ONE principal against the SAME owned_ref twice.
    #
    # The RUN numbering it left ragged is closed (K-712d): there had never been
    # a RUN 3, and RUN 4 ("C2 — unpaid second reservation") was the SAME call
    # and the SAME assertion as RUN 2 with the label strings changed, so it
    # bought a second server boot and a second Equihash registration for a
    # property already proved. The runs below are 1, 2, 3 and contiguous.

    # ── RUN 3: Query-verb assertions — scooters_available + per-user my_reservations ──
    # Proves: (a) query scooters_available returns SK-001;
    #         (b) query my_reservations after reserve returns exactly the
    #             principal's reservation (app-layer per-user isolation, no RLS).
    puts "\n══ RUN 3: Query-verb assertions (scooters_available + my_reservations per-user) ══"
    boot_server.call do
      require "net/http"
      require "openssl"
      require "securerandom"

      # THE 0.4 WIRE. An action is `POST <endpoint>/<action-name>` carrying its
      # arguments as the JSON body; a query is `GET <endpoint>/<query-name>`
      # carrying them in the query string. There is no `name` field and no
      # /query or /run endpoint, and a success body IS the result — a bare array
      # from a non-paginating query, the action's own object from an action.
      #
      # Helper: one POST and return [status_int, parsed_body].
      q_post = lambda do |path, body_hash, bearer, pow = nil|
        uri = URI("#{server_url}#{path}")
        req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{bearer}")
        req["Kiosk-PoW"] = JSON.generate(pow) if pow
        req.body = JSON.generate(body_hash)
        res = Net::HTTP.new(uri.host, uri.port).request(req)
        [res.code.to_i, JSON.parse(res.body)]
      end

      # Helper: one GET (a query) and return [status_int, parsed_body].
      q_get = lambda do |path, params, bearer|
        uri = URI("#{server_url}#{path}")
        uri.query = URI.encode_www_form(params) unless params.empty?
        req = Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{bearer}")
        res = Net::HTTP.new(uri.host, uri.port).request(req)
        [res.code.to_i, JSON.parse(res.body)]
      end

      # Register a fresh agent through the Equihash-gated /auth/register — the
      # shared helper again (K-696), which asserts the 201 this block used to
      # assert for itself.
      _q_key, reg_data = equihash_register(
        server: server_url, issuer: kiosk_issuer,
        get_json: reg_get, post_json: reg_post,
      )
      q_token   = reg_data.fetch("access_token")
      q_user_id = reg_data.fetch("user_id")

      # KYC the agent (valid attestation via ProveTestIssuer — ProveKey-signed).
      require_relative "../../script/prove_test_issuer"
      q_att = ProveTestIssuer.attest(user_id: q_user_id)
      q_post.call("/kiosk/agents/kyc", { kyc_jws: q_att }, q_token)

      # ── QA1: query scooters_available — SK-001 must be present ──────────
      qa1_rc, qa1_resp = q_get.call("/kiosk/scooters_available", {}, q_token)
      if qa1_rc == 200
        codes = Array(qa1_resp).map { |r| r["code"] }
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
      qa2_rc, qa2_resp = q_get.call("/kiosk/my_reservations", {}, q_token)
      if qa2_rc == 200
        rows_before = Array(qa2_resp)
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
        "/kiosk/reserve",
        { scooter_code: "SK-001" },
        q_token,
      )
      abort "RUN6 reserve failed (#{rsv_rc}): #{rsv_data.inspect}" unless rsv_rc == 200
      q_reservation_id = rsv_data["reservation_id"]
      puts "  Reserved: #{q_reservation_id}"

      # ── QA3: query my_reservations after reservation — exactly 1 row ─────
      # Demonstrates app-layer per-user isolation: only this principal's
      # reservation is visible; not rows from other principals (RUN 1 etc.).
      qa3_rc, qa3_resp = q_get.call("/kiosk/my_reservations", {}, q_token)
      if qa3_rc == 200
        rows_after = Array(qa3_resp)
        if rows_after.size == 1 && rows_after.first["reservation_id"] == q_reservation_id
          puts "  OK  QA3 my_reservations (after reserve): exactly 1 row, reservation_id matches"
        else
          failures << "qa3: my_reservations expected [{reservation_id:#{q_reservation_id}}], got #{rows_after.inspect}"
          puts "  FAIL  QA3 my_reservations after reserve: expected 1 row with reservation_id=#{q_reservation_id}, got #{rows_after.inspect}"
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

    # ── The capture→settlement window (K-853 / protocol.md §11.6) ─────────
    # NO SERVER. The two halves of the window cannot be stood in over HTTP —
    # holding a capture mid-charge and observing a returned capture with no
    # settlement row need a controllable PSP and the provider called directly —
    # so this run is IN-PROCESS against the same database, driving the real
    # verbs through the registry the wire dispatches to. It rides inside
    # demo:rideflow rather than becoming its own task because demo:rideflow is
    # already this demo's pay-path gate.
    puts "\n══ Capture-anchored paid state (K-853) ══"
    window_rb = File.expand_path("../../script/pay_window.rb", __dir__)
    unless system("bundle exec rails runner #{window_rb.shellescape}")
      failures << "pay_window: capture-window assertions failed (see output above)"
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
    Adversarial cross-tenant isolation test.

    Runs demo:setup (clean DB + seed), boots the server, runs script/isolation_flow.rb
    with two fresh principals (A and B), and asserts all cross-tenant denial properties:

      Assertion 1 (ownership denial — Gate 1 isolated): B rides a licence-free
        scooter (Gate 1b) and settles a payment mandate referencing rA (Gate 2)
        then calls start_rental on A's reservation_id. Gate 1
        (user_id = kiosk.current_user_id() AND status='reserved') finds
        nothing → 403. The 403 isolates Gate 1 ownership because Gate 1b and
        Gate 2 are both genuinely satisfied by B (start_rental has no KYC gate
        — K-442).
      Assertion 2a (exclusion): B's my_reservations does NOT contain A's reservation.
      Assertion 2b (positive control): B's my_reservations DOES contain B's own
        reservation, proving the exclusion is not vacuous.
      Assertion 3a (the principal is not an input): B calls reserve with a
        forged user_id arg (A's UUID) → 400 bad_request naming user_id, refused
        by the published input_schema before the handler runs.
      Assertion 3b (ownership comes from the token): B's LEGITIMATE reservation
        has DB user_id == B (the server writes kiosk.current_user_id()).

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-skooti-isolation.log"

    # ── host resolution ────────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("skooti.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "skooti.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 skooti.demo.kiosk.tech — using 127.0.0.1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_skooti_development"

    puts "\n── Starting skooti (isolation test) on #{server_url} ──"

    # The isolation driver attests agents with ProveTestIssuer (the ProveKey),
    # so the server must be told to TRUST that key explicitly — skooti no
    # longer ships a pinned dev ProveKey (K-650).
    require_relative "../../script/prove_test_issuer"

    # ── boot the server ────────────────────────────────────────────────────
    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER"               => kiosk_issuer,
        "KIOSK_PROVE_PUBLIC_KEY_PEM" => ProveTestIssuer.public_key_pem },
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

    # ── run script/isolation_flow.rb ──────────────────────────────────────────────
    flow_rb = File.expand_path("../../script/isolation_flow.rb", __dir__)
    puts "\n── Running script/isolation_flow.rb (adversarial cross-tenant) ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "script/isolation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_a         = result["user_id_a"]
    user_id_b         = result["user_id_b"]
    reservation_id_a  = result["reservation_id_a"]
    reservation_id_b  = result["reservation_id_b"]
    forged_refusal    = result["forged_refusal"] || []
    b_start_rental_rc = result["b_start_rental_rc"]
    b_reservation_ids = result["b_reservation_ids"] || []

    # ── Assertion 1: B's start_rental on A's reservation → 403 ──────────
    # B passed Gate 1b (licence-free vehicle) and Gate 2 (payment for rA)
    # before this attempt; the 403 therefore isolates Gate 1 ownership
    # exclusively (start_rental has no KYC gate — K-442).
    if b_start_rental_rc == 403
      puts "  OK  Assertion 1: B's start_rental on A's rA #{reservation_id_a} → 403 (Gate 1 ownership denied; Gate 1b+2 passed)"
    else
      failures << "ISOLATION HOLE: B's start_rental on A's reservation returned #{b_start_rental_rc.inspect} (expected 403) — Gate 1 ownership bypass"
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
    if b_reservation_ids.include?(reservation_id_b)
      puts "  OK  Assertion 2b: B's my_reservations includes B's own #{reservation_id_b} (positive control — exclusion non-vacuous)"
    else
      failures << "B's my_reservations does not include B's own reservation #{reservation_id_b}; got #{b_reservation_ids.inspect} — positive control failed (vacuous exclusion)"
      puts "  FAIL  Assertion 2b: B's my_reservations missing B's own rB #{reservation_id_b} — positive control failed"
    end

    # ── Assertion 3a: the forged user_id is REFUSED by the published contract ──
    forged_rc, forged_code, forged_detail = forged_refusal
    if forged_rc == 400 && forged_code == "bad_request" && forged_detail.to_s.include?("user_id")
      puts "  OK  Assertion 3a: forged user_id → 400 bad_request naming user_id " \
           "(refused by input_schema before the handler runs)"
    else
      failures << "forged user_id not refused: #{forged_refusal.inspect}, want [400, \"bad_request\", …user_id…]"
      puts "  FAIL  Assertion 3a: forged user_id → #{forged_refusal.inspect} (want 400/bad_request naming user_id)"
    end

    # ── Assertion 3b: DB user_id on B's LEGITIMATE reservation == user_id_b ──
    # The half the refusal does not prove: ownership is taken from the
    # authenticated identity (kiosk.current_user_id()), never from an argument.
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM public.reservations WHERE id = '#{reservation_id_b}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  OK  Assertion 3b: DB reservations.user_id for rB == user_id_b (#{user_id_b}) — ownership is taken from the identity"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB reservations.user_id for rB is A's user_id (#{user_id_a}) — ownership did not come from the token"
      puts "  FAIL  Assertion 3b: reservation belongs to A, not B"
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
end

namespace :demo do
  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery — kiosk-redteam.

    Boots skooti, runs every generic Kiosk::Redteam scenario skooti's surface
    exposes plus skooti's own beats against the full chain (Equihash PoW n=96
    k=5 → KYC → reserve → pay → start_rental) and asserts each attack is
    BLOCKED. The suite prints the count it actually ran; this list names them.
    No count is kept here on purpose: a count kept here is a count that rots
    (K-710, and the guard commissioned by T-078 will diff this list against the
    suite's own registry):

      BLOCKED  PayForOtherUseSelf    — C2: B pays for A's reservation, tries start_rental
      BLOCKED  SpentResourceReuse    — C3: re-start_rental on already-active reservation
      BLOCKED  ExpiredKyc            — expired attestation rejected at /kyc
      BLOCKED  ForgedKyc             — wrong-key attestation rejected at /kyc
      BLOCKED  UnpaidGatedAction     — start_rental without payment → Gate 2 fires
      BLOCKED  CrossTenantRead       — B's my_reservations excludes A's rows
      BLOCKED  ForgedUserId          — agent-supplied user_id in reserve args refused (400)
      BLOCKED  RegistrationWithoutPow — /register without a valid Equihash proof rejected
      BLOCKED  MandatePrincipalSwap  — B signs mandate with A's identity; rejected
      BLOCKED  MandateReplay         — B re-submits A's JWS; rejected
      BLOCKED  TokenTampering        — altered JWT claim rejected 401
      BLOCKED  PrivilegeSelfSelection — agent cannot self-assign elevated privilege
      BLOCKED  WrongCurrencyCart     — pay own reservation in usd at a EUR operator → 403
      BLOCKED  TamperedPriceCart     — pay below the operator's quoted rental price → 403
      BLOCKED  InflatedTotalCart     — cart total ≠ the sum of its line items → 403
      BLOCKED  MalformedUuidArg      — a junk reservation_id, as an arg AND inside a
                                       signed cart, is a typed 400 with no SQL
                                       internals — never a 500
      BLOCKED  HostileArgShapes      — boolean/array/object/number on scooter_code,
                                       reservation_id and request_id → typed 400 (or,
                                       for an unknown id on a query, 404 not_found),
                                       never a 500 (K-773)
      BLOCKED  MotorcycleForgedKyc   — a forged attestation self-asserting
                                       {age_over_18, licence_a} leaves the
                                       attribute-gated rent_motorcycle at 403
      BLOCKED  MotorcycleViaStartRental — the KYC gate cannot be walked around by VERB:
                                       reserve(MC-001) → pay → start_rental is refused,
                                       not answered with an unlock token (K-687)
      BLOCKED  IssuedKycJwsTheft     — a REAL issuer-signed jws minted for victim B
                                       cannot be replayed by attacker A; A's
                                       rent_motorcycle stays 403 (K-440/K-443)
      BLOCKED  CrossOperatorClaimReplay — a broker-signed claim addressed to ANOTHER
                                       operator is rejected at skooti's /kyc/callback
      BLOCKED  ForgedCallbackNoSig   — a /kyc/callback whose jws is wrong-key (or
                                       absent) is rejected; kyc_status stays pending
      BLOCKED  RetiredWire           — POST /kiosk/query and POST /kiosk/run are an
                                       ordinary 404 not_found: the 0.3 pair was DELETED,
                                       so no privileged endpoint and no second
                                       conformance surface remain
      BLOCKED  MethodMismatch        — a GET at an action's path (and a POST at a
                                       query's) is 405 method_not_allowed with Allow,
                                       never a silent 404
      BLOCKED  SelfAssertedTokenForgery — a self-asserted `agent:u-…:a-…:r-owner`
                                       bearer resolves to NO identity (401), while the
                                       genuinely-bound token is still answered
      BLOCKED  SelfAssertedUserBearerForgery — a forged `user:u-<uuid>` bearer at
                                       /kiosk/auth/link is 401, while the seeded
                                       rider's real Devise session is answered

    Exits 0 when all scenarios are BLOCKED; exits 1 on any BREACH.
    A BREACH = a real hole in skooti — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"
    require_relative "../../script/prove_broker_boot"
    require_relative "../../script/prove_test_issuer"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-skooti-redteam.log"

    # ── host resolution ────────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("skooti.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "skooti.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 skooti.demo.kiosk.tech — using 127.0.0.1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    # TWO-SERVER GATE: the broker-flavored beats (IssuedKycJwsTheft via the
    # broker, CrossOperatorClaimReplay, ForgedCallbackNoSig) drive the broker, so
    # boot the broker first and wire skooti's trust/intake config at it.
    exit_status = nil
    ProveBrokerBoot.with_broker(skooti_host: host, log: "/tmp/kiosk-prove-broker-redteam.log") do |broker|
      # The one gate that runs BOTH issuance paths — the running broker's key
      # (fetched at /prove_key.pem and pinned as skooti's trust anchor) and the
      # driver's own ProveTestIssuer — so it is where their lockstep is checked
      # (K-681). A drift makes every valid-KYC control look like a forgery;
      # this says which two files disagree instead.
      ProveTestIssuer.assert_matches_broker!(broker[:wiring]["KIOSK_PROVE_PUBLIC_KEY_PEM"])

      puts "\n── Starting skooti (redteam battery) on #{server_url} ──"

      # ── boot the server ──────────────────────────────────────────────────
      env_vars = { "KIOSK_ISSUER" => kiosk_issuer }.merge(broker[:wiring])

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

      # ── wait for readiness ───────────────────────────────────────────────
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

      # ── run script/redteam_suite.rb ─────────────────────────────────────────────
      suite_rb = File.expand_path("../../script/redteam_suite.rb", __dir__)
      puts "\n── Running script/redteam_suite.rb (skooti + KYC broker) ──"

      # The driver mints valid/expired attestations via ProveTestIssuer and
      # forged ones via ProveTrust.issuer — both now read the same
      # ProveTrust.issuer (K-681), i.e. KIOSK_PROVE_ISSUER, so it MUST carry the
      # same pinned iss the broker stamps and skooti's server verifies against,
      # or the valid-KYC control mismatches iss.
      env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} " \
                "KIOSK_PROVE_BROKER_URL=#{broker[:broker_url]} " \
                "KIOSK_PROVE_ISSUER=#{broker[:wiring]['KIOSK_PROVE_ISSUER']} " \
                "KIOSK_PROVE_INTAKE_SECRET=#{broker[:wiring]['KIOSK_PROVE_INTAKE_SECRET']} " \
                "KIOSK_PROVE_OPERATOR_ID=#{broker[:wiring]['KIOSK_PROVE_OPERATOR_ID']}"

      system("#{env_str} bundle exec ruby #{suite_rb}")
      exit_status = $?.exitstatus
    end

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
  # ── demo:schema ────────────────────────────────────────────────────────────
  desc <<~DESC
    Self-discovery proof — verifies the schema verb over HTTP.

    Boots the server, registers a fresh agent (Equihash PoW n=96 k=5), calls:
      GET /kiosk/schema

    Asserts:
      • `GET /kiosk/schema` answers 200 with NO Authorization header (public since T-094)
      • the MODULE set lives in /.well-known/kiosk.json `capabilities` (`verbs` dropped, T-095)
      • capabilities is the MODULE set schema/queries/actions/pay and NOT events
      • schema.actions includes reserve, start_rental, rent_motorcycle,
        payment_setup with descriptions
      • `payment_setup` and `kyc_status` publish BOTH a backing-off poll cadence and a GIVE UP horizon (K-606)

      • the `<link rel="kiosk">` tag AND the `Link: <…>; rel="kiosk"` header both name
        a VERSIONED cut — not the mutable `skill.md` alias — and both agree with the
        `skill` pin in /.well-known/kiosk.json (K-927, protocol.md §4.5)

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-skooti-schema.log"

    host = begin
      addr = begin
        Resolv.getaddress("skooti.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      addr == "127.0.0.1" ? "skooti.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting skooti (schema proof) on #{server_url} ──"

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

    # ── K-927: THE DISCOVERY SIGNAL, READ OFF THE WIRE ───────────────────────
    #
    # protocol.md §4.5 (Phil, 2026-08-21): an operator that advertises
    # `rel="kiosk"` MUST point it at a VERSIONED cut
    # (`https://kiosk.tech/skill-vMAJOR.MINOR.PATCH.md`), MUST NOT point it at
    # the mutable `skill.md` alias, and — where it also publishes a `skill` pin
    # — the tag, the header and the pin MUST all name the SAME url.
    #
    # ASSERTED HERE, OVER HTTP, AND NOT IN A UNIT TEST, because the defect
    # K-927 recorded was a SERVED BYTE: the tag is rendered by a view and the
    # header is set by a controller, so only a real response says what an
    # assistant scanning this page is actually handed. bin/check-version-parity
    # holds the SOURCE half (no literal url in app/, read the accessor); this
    # holds the wire half. The expected url is read from the origin's own
    # `/.well-known/kiosk.json`, never from a constant here — a second copy of
    # the pin is the thing both halves exist to prevent.
    require "net/http"
    require "uri"

    puts "\n── Discovery-signal assertions (K-927, protocol.md §4.5) ──"
    versioned_cut = %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}
    pinned_skill  =
      begin
        JSON.parse(Net::HTTP.get(URI("#{server_url}/.well-known/kiosk.json")))
            .dig("kiosk", "skill", "url")
      rescue StandardError => e
        failures << "could not read the kiosk.json skill pin: #{e.class}: #{e.message}"
        nil
      end

    advertised = { %(<link rel="kiosk"> tag) => nil, %(Link: <…>; rel="kiosk" header) => nil }
    %w[/].each do |page|
      res = Net::HTTP.get_response(URI("#{server_url}#{page}"))
      advertised[%(<link rel="kiosk"> tag)] ||=
        res.body.to_s[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
      advertised[%(Link: <…>; rel="kiosk" header)] ||=
        res["Link"].to_s[/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
    end

    advertised.each do |what, url|
      if url.nil? || url.empty?
        failures << "#{what}: absent from #{%w[/].join(", ")} — §4.5's signal is not served"
        puts "  ✗  #{what} absent from #{%w[/].join(", ")}"
        next
      end

      if url == "https://kiosk.tech/skill.md"
        failures << "#{what} names the MUTABLE alias #{url} — §4.5 forbids it (K-927)"
        puts "  ✗  #{what} names the mutable alias #{url}"
      elsif versioned_cut.match?(url)
        puts "  ✓  #{what} names the versioned cut #{url}"
      else
        failures << "#{what} names #{url.inspect}, which is not a skill-vX.Y.Z.md cut (§4.5)"
        puts "  ✗  #{what} names #{url.inspect}, not a versioned cut"
      end

      next if pinned_skill.nil? || url == pinned_skill

      failures << "#{what} names #{url.inspect} but /.well-known/kiosk.json pins " \
                  "#{pinned_skill.inspect} — one origin advertises ONE skill (§4.5)"
      puts "  ✗  #{what} disagrees with the kiosk.json skill pin #{pinned_skill.inspect}"
    end
    if pinned_skill && advertised.values.compact.uniq == [pinned_skill]
      puts "  ✓  both signals and the kiosk.json `skill` pin name one url: #{pinned_skill}"
    end

    queries      = result["schema_queries"] || []
    actions      = result["schema_actions"] || []
    capabilities = result["discovery_capabilities"] || []

    # THE SCHEMA CALL WAS MADE WITHOUT A CREDENTIAL (T-094). The flow driver
    # sends no Authorization header, so this status IS the public-access proof.
    if result["schema_status"] == 200
      puts "  ✓  GET /kiosk/schema answered 200 with NO Authorization header"
    else
      failures << "unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}, want 200"
      puts "  ✗  unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}"
    end

    # THE MODULE SET, at its one remaining home. It was published twice —
    # `schema.verbs` and `kiosk.json` `capabilities` — from the same call, so
    # `verbs` was dropped (T-095) and the property moved here intact.
    %w[schema queries actions pay].each do |v|
      if capabilities.include?(v)
        puts "  ✓  capabilities includes #{v}"
      else
        failures << "capabilities missing #{v} (got #{capabilities.inspect})"
        puts "  ✗  capabilities missing #{v}"
      end
    end
    if capabilities.include?("events")
      failures << "capabilities must NOT include events (got #{capabilities.inspect})"
      puts "  ✗  capabilities must NOT include events"
    else
      puts "  ✓  capabilities does not include events"
    end

    # reserve present with a description (reserve is an Action, not a query)
    reserve_entry = actions.find { |a| a["name"] == "reserve" }
    if reserve_entry
      puts "  ✓  schema.actions includes reserve"
      if reserve_entry["description"] && !reserve_entry["description"].to_s.empty?
        puts "  ✓  reserve has description: #{reserve_entry["description"].inspect}"
      else
        failures << "reserve missing description"
        puts "  ✗  reserve missing description"
      end
    else
      failures << "schema.actions missing reserve"
      puts "  ✗  schema.actions missing reserve"
    end

    # T-042 / K-452: the primary read query (scooters_available) and primary
    # action (reserve) advertise the machine-readable descriptor extensions.
    {
      queries => %w[scooters_available],
      actions => %w[reserve],
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

    # start_rental, rent_motorcycle (the KYC-gated action), request_kyc (the
    # external stub-issuer trigger, K-440/K-443), payment_setup (skill Step 5)
    # present with descriptions
    %w[start_rental rent_motorcycle request_kyc payment_setup].each do |aname|
      entry = actions.find { |a| a["name"] == aname }
      if entry
        puts "  ✓  schema.actions includes #{aname}"
        if entry["description"] && !entry["description"].to_s.empty?
          puts "  ✓  #{aname} has description: #{entry["description"].inspect}"
        else
          failures << "#{aname} missing description"
          puts "  ✗  #{aname} missing description"
        end
      else
        failures << "schema.actions missing #{aname}"
        puts "  ✗  schema.actions missing #{aname}"
      end
    end

    # kyc_status query (poll a request_kyc verification) present with a description
    kyc_status_entry = queries.find { |q| q["name"] == "kyc_status" }
    if kyc_status_entry && kyc_status_entry["description"].to_s != ""
      puts "  ✓  schema.queries includes kyc_status with description"
    else
      failures << "schema.queries missing kyc_status (or no description)"
      puts "  ✗  schema.queries missing kyc_status (or no description)"
    end

    # ── K-606: THE POLL BUDGET IS A PUBLISHED CONTRACT, SO IT IS ASSERTED ─────
    # The out-of-band verbs below are learned about by RE-POLLING and nothing
    # else — the wire has no server→assistant push — so K-477/K-595 wrote a
    # cadence and a give-up horizon into their descriptors and K-605 made them
    # QUOTE kiosk.tech/skill.md's tiered schedule instead of a rival flat one.
    # Until this beat nothing that runs read either back: `grep` found the
    # strings only in the source they were written into, so any later edit could
    # drop the horizon and every gate stayed green. It is asserted here, on the
    # SERVED descriptor, because that is the document an assistant reads.
    #
    # STRUCTURE, NOT THE MINUTES. Both tiers must be present, the second must be
    # SLOWER than the first (a tiering that is not one is not a schedule), and a
    # horizon must be named in minutes. The exact numbers are deliberately NOT
    # pinned: writing "5" and "15" here would make this file a third place the
    # schedule lives, which is the divergence K-605 closed by deleting a derived
    # count rather than recomputing it.
    poll_tiers   = /re-check every ~(\d+) seconds for the first minute, then every ~(\d+) seconds/
    poll_horizon = /GIVE UP after about (\d+) minutes?/
    { actions => ["payment_setup"], queries => ["kyc_status"] }.each do |list, names|
      names.each do |vname|
        entry = list.find { |e| e["name"] == vname }
        if entry.nil?
          failures << "schema is missing #{vname} — the poll-budget assertion cannot run (K-606)"
          puts "  FAIL  schema is missing #{vname} (K-606)"
          next
        end
        desc = entry["description"].to_s
        tiers   = desc.match(poll_tiers)
        horizon = desc.match(poll_horizon)
        if tiers.nil?
          failures << "#{vname} description publishes no poll cadence (K-477/K-605): #{desc.inspect}"
          puts "  FAIL  #{vname} publishes no poll cadence"
        elsif tiers[2].to_i <= tiers[1].to_i
          failures << "#{vname} cadence does not back off: ~#{tiers[1]}s then ~#{tiers[2]}s (K-605)"
          puts "  FAIL  #{vname} cadence does not back off (~#{tiers[1]}s then ~#{tiers[2]}s)"
        else
          puts "  OK    #{vname} publishes a backing-off cadence (~#{tiers[1]}s, then ~#{tiers[2]}s)"
        end
        if horizon.nil? || horizon[1].to_i <= 0
          failures << "#{vname} description publishes no GIVE UP horizon (K-477): #{desc.inspect}"
          puts "  FAIL  #{vname} publishes no GIVE UP horizon"
        else
          puts "  OK    #{vname} publishes a give-up horizon (~#{horizon[1]} minutes)"
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
  # ── end demo:schema ────────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:kyc ───────────────────────────────────────────────────────────────
  desc <<~DESC
    KYC named-anonymized-attribute gate proof — via the EXTERNAL stub issuer.

    Runs demo:setup (clean DB + seed SK-001 scooter + MC-001 motorcycle), boots
    the server, runs script/kyc_flow.rb and asserts a fresh EXTERNAL agent (own keypair
    only, NO pre-shared issuer key) drives motorcycle KYC to success by relaying
    a human-approve link, plus the KYC-free scooter positive control:

      A1  rent_motorcycle WITHOUT KYC        → 403 whose RFC 9457 problem document
          carries the TOP-LEVEL code "kyc_required", and whose `hint` points the
          agent at `request_kyc` (K-440/K-443 fix)
      A2  POST /kiosk/request_kyc            → 200, returns a verification_url on
          the skooti host; human approves the stub KYC-provider page; poll
          GET /kiosk/kyc_status?request_id=… → approved returns the signed kyc_jws
      A3  submit the relayed kyc_jws to      → 200 (attributes {age_over_18,
          POST /agents/kyc                      licence_a} recorded)
      A4  rent_motorcycle WITH KYC           → 200, offline token unlocks the lock
      B   start_rental SK-001 with NO KYC    → 200 (licence-free; no attribute leak)

    Exits 0 when all hold; exits 1 on any miss. A red assertion = the KYC gate is
    broken (or leaked onto the scooter path) — fix the app, not the test.

    RUNS spec/licence_flag_spec.rb FIRST (K-724). Beat B above and the redteam
    battery's MotorcycleViaStartRental both drive the real schema, so they only
    ever hand the licence gate a real Ruby boolean — the one input on which a
    fail-OPEN hand-rolled coercion and the correct cast agree. The spec presents
    the spellings the wire cannot ("TRUE", 1, "yes", NULL) and asserts each one
    still BLOCKS. It boots nothing and takes no port, so it costs this task a
    single `rails runner`.
  DESC
  task kyc: :setup do
    spec = File.expand_path("../../spec/licence_flag_spec.rb", __dir__)
    puts "\n── K-724 licence-flag fail-closed spec (no server, no port) ──"
    sh "bundle exec rails runner #{spec}"

    require "resolv"
    require "net/http"
    require "uri"
    require "json"
    require "shellwords"
    require_relative "../../script/prove_broker_boot"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-skooti-kyc.log"

    host = begin
      addr = begin
        Resolv.getaddress("skooti.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      addr == "127.0.0.1" ? "skooti.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    # TWO-SERVER GATE: boot the KYC broker first, wire skooti's trust +
    # intake config at it, then boot skooti and drive the cross-app KYC flow.
    result = nil
    ProveBrokerBoot.with_broker(skooti_host: host) do |broker|
      puts "\n── Starting skooti (KYC-gate proof) on #{server_url} ──"

      File.truncate(log, 0) if File.exist?(log)
      server_pid = spawn(
        { "KIOSK_ISSUER" => kiosk_issuer }.merge(broker[:wiring]),
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

      flow_rb = File.expand_path("../../script/kyc_flow.rb", __dir__)
      puts "\n── Running script/kyc_flow.rb (skooti + KYC broker) ──"
      # KIOSK_PROVE_ISSUER must reach the DRIVER too, not only the server: PART C
      # mints its own attestation through ProveTestIssuer, whose `iss` is
      # ProveTrust.issuer — and without this the driver falls back to the
      # DEPLOYED broker origin while the booted broker stamps the harness's
      # local one, so a perfectly-signed attestation comes back 403 «issuer
      # mismatch». getgrocery's demo:agecheck has always passed it; this task
      # did not, because until PART C nothing in this driver signed anything.
      driver_env = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} " \
                   "KIOSK_PROVE_BROKER_URL=#{broker[:broker_url]} " \
                   "KIOSK_PROVE_ISSUER=#{broker[:wiring]["KIOSK_PROVE_ISSUER"]}"
      raw = `#{driver_env} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      stderr_lines = raw.lines.reject { |l| l.start_with?("{") }
      json_line    = raw.lines.grep(/^\{/).last
      puts stderr_lines.join
      puts json_line if json_line

      begin
        result = JSON.parse(json_line || raw)
      rescue JSON::ParserError => e
        abort "script/kyc_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
      end
    end

    puts "\n── KYC-gate assertions ──"
    failures = []

    # A1: rent_motorcycle without KYC → 403 kyc_required AND the hint points the
    # agent at request_kyc (the K-440/K-443 discoverable-path fix).
    if result["http_mc_rent_no_kyc"] == 403 && result["mc_rent_no_kyc_code"] == "kyc_required"
      puts "  OK  A1 rent_motorcycle without KYC → 403 kyc_required"
    else
      failures << "A1: rent_motorcycle without KYC expected 403/kyc_required, got #{result["http_mc_rent_no_kyc"].inspect}/#{result["mc_rent_no_kyc_code"].inspect}"
      puts "  FAIL  A1 rent_motorcycle without KYC → #{result["http_mc_rent_no_kyc"].inspect}/#{result["mc_rent_no_kyc_code"].inspect}"
    end
    if result["mc_rent_no_kyc_hint_to_req"] == true
      puts "  OK  A1 403 hint points to request_kyc (agent can discover the path)"
    else
      failures << "A1: 403 hint does not point to request_kyc"
      puts "  FAIL  A1 403 hint does not point to request_kyc"
    end

    # A2: the SHARED-BROKER issuer path — request_kyc returned a verification_url
    # on the KYC BROKER host, the broker approve page accepted the token,
    # the broker POSTed its signed claim to skooti's callback, kyc_status reached
    # approved, and the broker-signed jws was relayed back (the agent never held
    # the signing key).
    vurl = result["request_kyc_verification_url"].to_s
    if result["http_request_kyc"] == 200 && vurl.include?("/verify?request=")
      puts "  OK  A2 request_kyc → 200 with broker verification_url #{vurl.inspect}"
    else
      failures << "A2: request_kyc expected 200 with a /verify?request= broker url, got #{result["http_request_kyc"].inspect}/#{vurl.inspect}"
      puts "  FAIL  A2 request_kyc → #{result["http_request_kyc"].inspect}/#{vurl.inspect}"
    end
    # A2b: the OUTSTANDING-INTAKE CAP (K-586). One registration proof bought
    # unlimited broker intakes — free against a stub, a budget hole behind a
    # paid issuer, and a licence check is the expensive kind. The FOURTH
    # pending request for one account is refused with the wire's own
    # `quota_exceeded` (429), BEFORE the broker is called.
    if result["http_request_kyc_capped"] == 429 && result["request_kyc_capped_code"] == "quota_exceeded"
      puts "  OK  A2b a fourth PENDING request_kyc → 429 quota_exceeded (per-principal cap)"
    else
      failures << "A2b: fourth pending request_kyc expected 429/quota_exceeded, got #{result["http_request_kyc_capped"].inspect}/#{result["request_kyc_capped_code"].inspect}"
      puts "  FAIL  A2b fourth PENDING request_kyc → #{result["http_request_kyc_capped"].inspect}/#{result["request_kyc_capped_code"].inspect}"
    end

    if result["http_approve_page"] == 200 && result["kyc_status"] == "approved" && result["kyc_jws_relayed"] == true
      puts "  OK  A2 human approved broker page → callback landed, kyc_status approved, broker-signed jws relayed (no pre-shared key)"
    else
      failures << "A2: broker path expected approve=200/status=approved/jws relayed, got approve=#{result["http_approve_page"].inspect}/status=#{result["kyc_status"].inspect}/jws=#{result["kyc_jws_relayed"].inspect}"
      puts "  FAIL  A2 broker path → approve=#{result["http_approve_page"].inspect}/status=#{result["kyc_status"].inspect}/jws=#{result["kyc_jws_relayed"].inspect}"
    end

    # A3: the relayed jws is accepted at /agents/kyc and records both attributes.
    attrs = result["kyc_attributes"] || {}
    if result["http_kyc_submit"] == 200 && attrs["age_over_18"] == true && attrs["licence_a"] == true
      puts "  OK  A3 relayed kyc_jws accepted at /agents/kyc with {age_over_18, licence_a}"
    else
      failures << "A3: KYC submit expected 200 with both attributes, got #{result["http_kyc_submit"].inspect}/#{attrs.inspect}"
      puts "  FAIL  A3 KYC submit → #{result["http_kyc_submit"].inspect}/#{attrs.inspect}"
    end

    # A4: rent_motorcycle with KYC → 200 and the offline token unlocks.
    if result["http_mc_rent_with_kyc"] == 200 && result["mc_unlocked"] == true
      puts "  OK  A4 rent_motorcycle with KYC → 200, motorcycle unlocked"
    else
      failures << "A4: rent_motorcycle with KYC expected 200/unlocked, got #{result["http_mc_rent_with_kyc"].inspect}/#{result["mc_unlocked"].inspect}"
      puts "  FAIL  A4 rent_motorcycle with KYC → #{result["http_mc_rent_with_kyc"].inspect}/#{result["mc_unlocked"].inspect}"
    end

    # B: scooter positive control — start_rental succeeds with NO KYC submitted
    # at all (K-442), proving licence-free scooters carry no KYC gate; only the
    # combustion motorcycle (rent_motorcycle) is KYC-gated.
    if result["http_scooter_rent_no_kyc"] == 200 && result["scooter_rented_no_kyc"] == true
      puts "  OK  B  start_rental SK-001 with NO KYC → 200 (licence-free scooters are not KYC-gated)"
    else
      failures << "B: scooter start_rental with no KYC expected 200, got #{result["http_scooter_rent_no_kyc"].inspect}/rented=#{result["scooter_rented_no_kyc"].inspect}"
      puts "  FAIL  B  scooter start_rental (no KYC) → #{result["http_scooter_rent_no_kyc"].inspect}/rented=#{result["scooter_rented_no_kyc"].inspect}"
    end

    # C: THE FAIL-CLOSED BOOLEAN (K-656). A genuinely broker-signed attestation
    # whose booleans are spelled "true" (a JSON string) and 1 is ACCEPTED as an
    # attestation and grants NOTHING — so the agent A4 just cleared loses its
    # clearance and the motorcycle it unlocked is refused again with
    # kyc_required. Presence of a row is the grant, and only the JSON boolean
    # writes one; there is no stored value a gate could misread.
    if result["http_spelling_kyc_submit"] == 200 && (result["spelling_attributes"] || {}).empty?
      puts "  OK  C1 broker-signed attestation with \"true\"/1 spellings → 200, attributes {} (nothing granted)"
    else
      failures << "C1: string/number-spelled attributes expected 200 with {}, got " \
                  "#{result["http_spelling_kyc_submit"].inspect}/#{result["spelling_attributes"].inspect}"
      puts "  FAIL  C1 spelled attestation → #{result["http_spelling_kyc_submit"].inspect}/#{result["spelling_attributes"].inspect}"
    end

    if result["http_mc_rent_after_spelling"] == 403 && result["mc_rent_after_spelling_code"] == "kyc_required"
      puts "  OK  C2 Gate 0 fails CLOSED on it — rent_motorcycle back to 403 kyc_required for an agent that HAD passed"
    else
      failures << "C2: rent_motorcycle after the spelled attestation expected 403 kyc_required, got " \
                  "#{result["http_mc_rent_after_spelling"].inspect}/#{result["mc_rent_after_spelling_code"].inspect}"
      puts "  FAIL  C2 rent_motorcycle after spelling → #{result["http_mc_rent_after_spelling"].inspect}/#{result["mc_rent_after_spelling_code"].inspect}"
    end

    if failures.empty?
      puts "\n  All KYC-gate assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:kyc ─────────────────────────────────────────────────────────────
end

desc "End-to-end Kiosk skooti demo: setup the DB then prove the full rental chain."
task demo: ["demo:setup", "demo:rideflow"]
