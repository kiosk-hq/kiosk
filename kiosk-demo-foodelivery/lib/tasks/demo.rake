# frozen_string_literal: true

# Kiosk demo orchestration. Tasks:
#
#   rake demo:setup        idempotent db:drop / create / migrate / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase, tears down
#   rake demo:order        boots the server, runs order_flow.rb (no-human full order),
#                          asserts DB row counts, tears down
#   rake demo              setup + order (the full end-to-end proof)
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

  desc "Boot the server and run the curl demo walkthrough."
  task :walkthrough do
    exec File.expand_path("../../bin/demo", __dir__)
  end

  desc "Boot the server, run the no-human order_flow.rb end-to-end, assert DB rows."
  task :order do
    require "resolv"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-foodelivery-demo.log"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = Resolv.getaddress("foodelivery.app") rescue ""
      if addr == "127.0.0.1"
        "foodelivery.app"
      else
        puts "  add to /etc/hosts:  127.0.0.1 foodelivery.app" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting foodelivery on #{server_url} ──"

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

    # ── run order_flow.rb ──────────────────────────────────────────────
    flow_rb = File.expand_path("../../order_flow.rb", __dir__)
    puts "\n── Running order_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "order_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    # ── assertions: HTTP + JSON ────────────────────────────────────────
    puts "\n── Assertions ──"
    failures = []

    pay   = result["pay"]   || {}
    order = result["order"] || {}

    if pay["ok"] == true
      puts "  ✓  pay.ok == true"
    else
      failures << "pay.ok is not true (got #{pay["ok"].inspect})"
      puts "  ✗  pay.ok — got #{pay["ok"].inspect}"
    end

    pm_id = pay.dig("value", "settlement_id")
    if pm_id && !pm_id.empty?
      puts "  ✓  pay.value.settlement_id present (#{pm_id})"
    else
      failures << "pay.value.settlement_id missing"
      puts "  ✗  pay.value.settlement_id missing"
    end

    oid = order["order_id"]
    if oid && !oid.empty?
      puts "  ✓  order.order_id present (#{oid})"
    else
      failures << "order.order_id missing"
      puts "  ✗  order.order_id missing"
    end

    # ── assertions: psql row counts ────────────────────────────────────
    db = "kiosk_foodelivery_development"

    orders_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM orders' 2>&1`.strip
    if orders_count == "1"
      puts "  ✓  orders count = 1"
    else
      failures << "orders COUNT expected 1, got #{orders_count.inspect}"
      puts "  ✗  orders COUNT expected 1, got #{orders_count.inspect}"
    end

    pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.settlements' 2>&1`.strip
    if pm_count == "1"
      puts "  ✓  kiosk.settlements count = 1"
    else
      failures << "kiosk.settlements COUNT expected 1, got #{pm_count.inspect}"
      puts "  ✗  kiosk.settlements COUNT expected 1, got #{pm_count.inspect}"
    end

    # ── query-verb assertions ──────────────────────────────────────────────
    # QA1: query menu_by_restaurant — proves agent browses via named query, not SQL.
    # QA2: query my_orders (before extra order) — empty for the fresh second principal.
    # QA3: query my_orders (after extra order) — exactly 1 row, scoped to that principal.
    # These run against the same running server (already up from order_flow.rb run above).
    puts "\n── Query-verb assertions ──"

    require "jwt"
    require "openssl"
    require "securerandom"

    q_post = lambda do |path, body_hash, bearer = ""|
      uri = URI("#{server_url}#{path}")
      req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json", "Authorization" => "Bearer #{bearer}" })
      req.body = JSON.generate(body_hash)
      res = Net::HTTP.new(uri.host, uri.port).request(req)
      [res.code.to_i, (JSON.parse(res.body) rescue {})]
    end

    q_get = lambda do |path, bearer = ""|
      uri = URI("#{server_url}#{path}")
      headers = {}
      headers["Authorization"] = "Bearer #{bearer}" unless bearer.to_s.empty?
      res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
      [res.code.to_i, (JSON.parse(res.body) rescue {})]
    end

    # Register a second fresh agent (different principal — proves per-user scoping)
    # via the proof-of-possession handshake: challenge → sign RS256 JWS → register.
    q_key = OpenSSL::PKey::RSA.generate(2048)
    q_pem = q_key.public_key.to_pem
    _q_ch_rc, q_ch = q_get.call("/kiosk/auth/challenge?public_key=#{URI.encode_www_form_component(q_pem)}")
    q_pop = JWT.encode(
      { aud: kiosk_issuer, nonce: q_ch["challenge"], jti: SecureRandom.uuid, iat: Time.now.to_i },
      q_key, "RS256",
    )
    q_reg_rc, q_reg = q_post.call(
      "/kiosk/auth/register",
      { public_key: q_pem, signed: q_pop },
    )
    if q_reg_rc == 201
      q_token   = q_reg["access_token"]
      q_user_id = q_reg["user_id"]

      # QA1: query menu_by_restaurant — Margherita must be present.
      qa1_rc, qa1_resp = q_post.call(
        "/kiosk/query",
        { name: "menu_by_restaurant", restaurant: "Mamma Pizza" },
        q_token,
      )
      if qa1_rc == 200
        qa1_rows = qa1_resp["rows"] || []
        qa1_skus = qa1_rows.map { |r| r["sku"] }
        if qa1_skus.include?("margherita")
          puts "  ✓  QA1 query menu_by_restaurant: margherita present (skus=#{qa1_skus.inspect})"
        else
          failures << "qa1: menu_by_restaurant — margherita not found, got skus=#{qa1_skus.inspect}"
          puts "  ✗  QA1 query menu_by_restaurant: margherita not found (skus=#{qa1_skus.inspect})"
        end
      else
        failures << "qa1: query menu_by_restaurant expected 200, got #{qa1_rc}"
        puts "  ✗  QA1 query menu_by_restaurant returned #{qa1_rc}: #{qa1_resp.inspect}"
      end

      # QA2: query my_orders before placing — must be empty for fresh principal.
      qa2_rc, qa2_resp = q_post.call(
        "/kiosk/query",
        { name: "my_orders" },
        q_token,
      )
      if qa2_rc == 200
        qa2_rows = qa2_resp["rows"] || []
        if qa2_rows.empty?
          puts "  ✓  QA2 my_orders (before order): empty for fresh principal (app-layer isolation)"
        else
          failures << "qa2: my_orders before order expected [], got #{qa2_rows.inspect}"
          puts "  ✗  QA2 my_orders before order: expected [], got #{qa2_rows.inspect}"
        end
      else
        failures << "qa2: query my_orders expected 200, got #{qa2_rc}"
        puts "  ✗  QA2 query my_orders returned #{qa2_rc}: #{qa2_resp.inspect}"
      end

      # Place an order for the second principal (needs menu_item_id from QA1).
      if qa1_rc == 200 && (qa1_margherita = (qa1_resp["rows"] || []).find { |r| r["sku"] == "margherita" })
        qa_menu_item_id = qa1_margherita.fetch("id")
        qa_place_rc, qa_place = q_post.call(
          "/kiosk/run",
          {
            name:             "place_order",
            menu_item_id:     qa_menu_item_id,
            quantity:         1,
            delivery_address: "2 Query St, Istanbul",
          },
          q_token,
        )
        if qa_place_rc == 200
          qa_order_id = qa_place.dig("value", "order_id")
          puts "  Placed QA order: #{qa_order_id}"

          # QA3: query my_orders after placing — exactly 1 row, this principal only.
          qa3_rc, qa3_resp = q_post.call(
            "/kiosk/query",
            { name: "my_orders" },
            q_token,
          )
          if qa3_rc == 200
            qa3_rows = qa3_resp["rows"] || []
            if qa3_rows.size == 1 && qa3_rows.first["id"] == qa_order_id
              puts "  ✓  QA3 my_orders (after order): exactly 1 row, id=#{qa_order_id} (app-layer per-user scoping)"
            else
              failures << "qa3: my_orders expected [{id:#{qa_order_id}}], got #{qa3_rows.inspect}"
              puts "  ✗  QA3 my_orders after order: expected 1 row with id=#{qa_order_id}, got #{qa3_rows.inspect}"
            end
          else
            failures << "qa3: query my_orders expected 200, got #{qa3_rc}"
            puts "  ✗  QA3 query my_orders returned #{qa3_rc}: #{qa3_resp.inspect}"
          end
        else
          failures << "qa: place_order for second principal failed (#{qa_place_rc}): #{qa_place.inspect}"
          puts "  ✗  QA place_order for second principal failed"
        end
      else
        failures << "qa: could not get margherita from QA1 — skipping QA3"
        puts "  ✗  QA: margherita row missing from QA1 — skipping QA3"
      end
    else
      failures << "qa: second agent register failed (#{q_reg_rc}): #{q_reg.inspect}"
      puts "  ✗  QA register failed (#{q_reg_rc})"
    end

    # ── RLS gone: confirm structure.sql has no ROW LEVEL SECURITY ───────────
    puts "\n── Structure check: no ROW LEVEL SECURITY on restaurants/menu_items/orders ──"
    structure_path = File.expand_path("../../db/structure.sql", __dir__)
    if File.exist?(structure_path)
      structure = File.read(structure_path)
      if structure.match?(/ROW LEVEL SECURITY/)
        failures << "structure.sql still contains ROW LEVEL SECURITY — regenerate after migration edit"
        puts "  ✗  structure.sql still contains ROW LEVEL SECURITY"
      else
        puts "  ✓  structure.sql: no ROW LEVEL SECURITY found"
      end
    else
      puts "  (structure.sql not found — skip RLS check)"
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
    log  = "/tmp/kiosk-foodelivery-pow-demo.log"

    host = begin
      addr = Resolv.getaddress("foodelivery.app") rescue ""
      addr == "127.0.0.1" ? "foodelivery.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting foodelivery (PoW demo) on #{server_url} ──"

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
      puts "  ✓  served after real solve.py: HTTP 200, #{result["menu_rows"]} menu rows"
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

  # ── demo:rls — additive RLS-enforce reference (R1 Phase 1 Task 5) ─────────
  desc <<~DESC
    RLS enforce reference (R1 Phase 1 Task 5) — strictly additive overlay; does NOT
    touch Path-C structure.sql and does NOT add any migration.

    Loads the normal structure.sql schema (db:drop → db:create → db:schema:load →
    db:seed — identical to demo:setup), then applies RLS as an IMPERATIVE OVERLAY
    via the kiosk-rls gem (Kiosk::RLS::Emitter — dogfooded).

    Role model:
      kiosk_foodelivery_app  NOLOGIN NOSUPERUSER NOBYPASSRLS   ← non-owner, subject to RLS
      GRANT kiosk_foodelivery_app TO CURRENT_USER              ← allows SET LOCAL ROLE

    Initializer gate (KIOSK_RLS_ENFORCE=1):
      c.enforce_db_role = true
      c.app_role        = "kiosk_foodelivery_app"
    SessionContext.open appends SET LOCAL ROLE "kiosk_foodelivery_app" after GUCs.

    Three-way proof (rls_proof.rb):
      1. Negative control: owner/superuser WITHOUT SessionContext sees BOTH rows
         (superuser bypasses RLS — the pre-fix no-op / leak).
      2. Enforced session for A: raw unscoped SELECT * FROM orders → only A's row.
      3. Enforced session for B: raw unscoped SELECT * FROM orders → only B's row.

    Exits 0 if all three assertions pass; exits 1 on any failure.
    Default `rake demo` (Path-C) is completely unaffected: structure.sql unchanged,
    no ROW LEVEL SECURITY in it, no migration added.
  DESC
  task :rls do
    # ── Step 1: Load structure.sql — identical to demo:setup (Path-C canonical) ─
    # No RLS, no migrations — the canonical structure.sql stays unchanged.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"

    # ── Step 2: Create the non-owner app role (idempotent) ──────────────────
    # NOLOGIN: cannot connect directly — only reachable via SET LOCAL ROLE.
    # NOSUPERUSER: does not bypass RLS (unlike the login/owner role).
    # NOBYPASSRLS: explicitly subject to all RLS policies (the default for
    #              non-superuser roles, but stated for clarity and production parity).
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_foodelivery_app') " \
       "THEN CREATE ROLE kiosk_foodelivery_app NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF; " \
       "END \\$\\$;\" >/dev/null"
    puts "  Role kiosk_foodelivery_app ensured (NOLOGIN NOSUPERUSER NOBYPASSRLS)."

    # ── Step 3: Grant kiosk_foodelivery_app to CURRENT_USER ─────────────────
    # Required so that the owner session can execute SET LOCAL ROLE kiosk_foodelivery_app
    # inside a transaction (SET ROLE requires membership; GRANT first makes
    # CURRENT_USER a member of the app role).
    sh "psql -d postgres -tAc 'GRANT kiosk_foodelivery_app TO CURRENT_USER' >/dev/null"
    puts "  GRANT kiosk_foodelivery_app TO CURRENT_USER — SET LOCAL ROLE now available."

    # ── Step 4: Apply RLS overlay via kiosk-rls Emitter (dogfooded) ─────────
    # rls_overlay.rb:
    #   GRANT USAGE ON SCHEMA public, kiosk
    #   Kiosk::RLS::Emitter.statements_for(orders_table):
    #     ALTER TABLE orders ENABLE ROW LEVEL SECURITY
    #     ALTER TABLE orders FORCE ROW LEVEL SECURITY      ← production-fidelity
    #     GRANT SELECT,INSERT,UPDATE,DELETE ON orders TO kiosk_foodelivery_app
    #     CREATE POLICY orders_select USING (user_id = kiosk.current_user_id())
    #     CREATE POLICY orders_insert WITH CHECK (user_id = kiosk.current_user_id())
    #     COMMENT ON TABLE orders IS '...'
    #
    # Run WITHOUT KIOSK_RLS_ENFORCE — overlay setup is privileged (owner connection).
    overlay_rb = File.expand_path("../../rls_overlay.rb", __dir__)
    puts "\n── Applying RLS overlay ──"
    sh "bundle exec rails runner #{overlay_rb}"

    # ── Step 5: Run the three-way isolation proof ────────────────────────────
    # KIOSK_RLS_ENFORCE=1 activates the initializer gate:
    #   c.enforce_db_role = true
    #   c.app_role        = "kiosk_foodelivery_app"
    # SessionContext.open then appends SET LOCAL ROLE "kiosk_foodelivery_app"
    # after the GUC statements.
    proof_rb = File.expand_path("../../rls_proof.rb", __dir__)
    puts "\n── Running RLS isolation proof (KIOSK_RLS_ENFORCE=1) ──"
    raw = `KIOSK_RLS_ENFORCE=1 bundle exec rails runner #{proof_rb} 2>&1`
    puts raw

    # ── Parse JSON and assert ────────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "rls_proof.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    puts "\n── RLS proof assertions ──"
    failures = []

    owner_sees = result["negative_control_owner_sees"].to_i
    if owner_sees == 2
      puts "  ✓  negative control: owner/superuser sees #{owner_sees} rows — no-op without role-drop (leak demonstrated)"
    else
      failures << "negative control: expected 2 rows, got #{owner_sees}"
      puts "  ✗  negative control FAILED: owner sees #{owner_sees} (expected 2)"
    end

    a_sees = result["enforced_a_sees"].to_i
    if a_sees == 1
      puts "  ✓  enforced session A: sees #{a_sees} row (own order only) — RLS backstop works"
    else
      failures << "enforced A: expected 1 row, got #{a_sees}"
      puts "  ✗  enforced A FAILED: sees #{a_sees} row(s) (expected 1)"
    end

    b_sees = result["enforced_b_sees"].to_i
    if b_sees == 1
      puts "  ✓  enforced session B: sees #{b_sees} row (own order only) — RLS backstop works"
    else
      failures << "enforced B: expected 1 row, got #{b_sees}"
      puts "  ✗  enforced B FAILED: sees #{b_sees} row(s) (expected 1)"
    end

    if failures.empty?
      puts "\n  RLS proof PASSED — FORCE+role-drop blocks raw cross-tenant SELECT."
      puts "  structure.sql is unchanged; default demo path unaffected."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:rls ──────────────────────────────────────────────────────────

  # ── demo:reputation ────────────────────────────────────────────────────────
  desc <<~DESC
    Reputation PoW demo (R2 P6 — trust-earned-by-spending).

    Boots the server with KIOSK_POW_REPUTATION_DEMO=1, runs reputation_flow.rb:
      0 purchases → 402 with 2 equihash challenges (unproven)
      1 purchase  → 402 with 1 challenge (purchase earns relief)
      2 purchases → 200 served directly, NO challenge (proven principal — free pass)

    Asserts:
      • proofs_unproven > proofs_after_1_purchase  (cost dropped with a purchase)
      • served_after_2_purchases == true           (query is free once proven)
      • challenge_after_2 == nil                   (no PoW issued to a proven principal)

    Prints the observed proof-count curve. Exits 0 on pass, 1 on failure.

    Policy: Kiosk::Reputation::Policies::RateAndReputation
      proven_purchases_threshold: 2, base_count: 1, unproven_count_bonus: 1
    Factors: real DB lookup — COUNT(*) FROM kiosk.settlements WHERE user_id = <principal>

    Requirements:
      python3 with numpy: pip install numpy
  DESC
  task :reputation do
    # Requirement: python3 with numpy (the equihash solver is vectorised).
    # Install with: pip install numpy
    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    unless python_ok
      abort "numpy not found. Install with: pip install numpy\n" \
            "Then re-run: bundle exec rake demo:reputation"
    end

    require "resolv"

    port = ENV.fetch("PORT", "3004")  # port 3004 to avoid conflict with demo:pow (3002)
    log  = "/tmp/kiosk-foodelivery-reputation-demo.log"

    host = begin
      addr = Resolv.getaddress("foodelivery.app") rescue ""
      addr == "127.0.0.1" ? "foodelivery.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting foodelivery (Reputation PoW demo) on #{server_url} ──"
    puts "   Policy: RateAndReputation (proven_purchases_threshold=2, base_d=3, unproven_d_bonus=2)"
    puts "   Factors: real DB lookup — kiosk.settlements WHERE user_id = <principal>"
    puts "   Expected curve: d=5 (0 purchases) → d=3 (1 purchase) → free pass (2 purchases)"

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
    n_after_1  = result["proofs_after_1_purchase"]
    served_2   = result["served_after_2_purchases"]
    n_after_2  = result["challenge_after_2"]

    # Print the observed proof-count curve.
    puts "  Proof-count curve: #{n_unproven} (0 purchases) → #{n_after_1} (1 purchase) → #{n_after_2.inspect} (2 purchases)"

    if n_unproven.to_i > n_after_1.to_i
      puts "  ✓  proof count dropped: #{n_unproven} → #{n_after_1} (purchase earns relief)"
    else
      failures << "expected proofs_unproven(#{n_unproven}) > proofs_after_1_purchase(#{n_after_1}) — cost must drop after first purchase"
      puts "  ✗  proof count did NOT drop after 1st purchase: #{n_unproven} → #{n_after_1}"
    end

    if served_2 == true && n_after_2.nil?
      puts "  ✓  free pass after 2 purchases: query served without any challenge (proven principal)"
    else
      failures << "expected served_after_2_purchases=true + challenge_after_2=nil; got served=#{served_2.inspect}, challenge=#{n_after_2.inspect}"
      puts "  ✗  NOT served without challenge after 2 purchases (served=#{served_2.inspect}, n_after_2=#{n_after_2.inspect})"
    end

    if failures.empty?
      puts "\n  All reputation assertions PASSED."
      puts "  Trust-earned-by-spending: PoW proof-count curve demonstrated end-to-end."
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:reputation ────────────────────────────────────────────────────

  # ---------------------------------------------------------------------------
  desc <<~DESC
    Adversarial cross-tenant isolation test (R1 Phase 1 Task 1).

    Boots the server, runs isolation_flow.rb with two fresh principals (A and B),
    and asserts all cross-tenant denial properties:

      Assertion 1 (exclusion): B's my_orders does NOT contain A's order oA.
      Assertion 2 (forged user_id ignored): B calls place_order with a forged
        user_id arg (A's UUID). The created order belongs to B (server uses
        kiosk.current_user_id(), ignores agent-supplied user_id). Verified by:
          - the order's DB user_id column == B's user_id (not A's)
          - B's my_orders contains the order
          - A's my_orders does NOT contain it
      ⚠️ Assertion 3 (pay/order binding) — NOT TESTABLE with current mandate
        structure: foodelivery's cart mandate carries line_items:[{sku,qty}] only;
        there is no order_id field in the mandate or pay args. Cross-principal
        settle cannot be fabricated. See report for the gap analysis.

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-foodelivery-isolation.log"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = Resolv.getaddress("foodelivery.app") rescue ""
      if addr == "127.0.0.1"
        "foodelivery.app"
      else
        puts "  add to /etc/hosts:  127.0.0.1 foodelivery.app" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting foodelivery (isolation test) on #{server_url} ──"

    # ── boot the server ────────────────────────────────────────────────
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

    user_id_a  = result["user_id_a"]
    user_id_b  = result["user_id_b"]
    order_id_a = result["order_id_a"]
    order_id_b = result["order_id_b"]
    b_before   = result["b_order_ids_before"] || []
    b_after    = result["b_order_ids_after"]  || []
    a_after    = result["a_order_ids_after"]  || []

    # ── Assertion 1: B's my_orders (before) excludes A's order ────────
    if b_before.include?(order_id_a)
      failures << "ISOLATION HOLE: B's my_orders (before) contains A's order #{order_id_a} — cross-tenant leak"
      puts "  ✗  Assertion 1 FAILED: B sees A's order #{order_id_a} — isolation hole"
    else
      puts "  ✓  Assertion 1: B's my_orders (before) excludes A's order #{order_id_a} (app-layer isolation)"
    end

    # ── Assertion 2a: B's my_orders (after forged place_order) contains oB ──
    if b_after.include?(order_id_b)
      puts "  ✓  Assertion 2a: B's my_orders (after forged order) includes oB #{order_id_b}"
    else
      failures << "B's my_orders (after forged order) does not contain oB #{order_id_b}; got #{b_after.inspect}"
      puts "  ✗  Assertion 2a FAILED: B's my_orders missing oB #{order_id_b}"
    end

    # ── Assertion 2b: A's my_orders (after B's forged order) excludes oB ──
    if a_after.include?(order_id_b)
      failures << "ISOLATION HOLE: A's my_orders contains B's forged order #{order_id_b} — cross-tenant leak"
      puts "  ✗  Assertion 2b FAILED: A sees B's order #{order_id_b} — isolation hole"
    else
      puts "  ✓  Assertion 2b: A's my_orders excludes B's forged order #{order_id_b}"
    end

    # ── Assertion 2c: DB user_id on oB is B's, not A's (forged arg ignored) ──
    db = "kiosk_foodelivery_development"
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM orders WHERE id = '#{order_id_b}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  ✓  Assertion 2c: DB orders.user_id for oB == user_id_b (#{user_id_b}) — forged arg ignored"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB orders.user_id for oB is A's user_id (#{user_id_a}) — forged user_id arg was NOT ignored"
      puts "  ✗  Assertion 2c FAILED: server used forged user_id arg (order belongs to A, not B)"
    else
      failures << "Unexpected user_id for oB: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  ✗  Assertion 2c FAILED: unexpected user_id #{db_user_id.inspect} for oB"
    end

    # ── Assertion 3 (⚠️ not testable — documented gap) ────────────────
    puts "\n  ⚠️  Assertion 3 (pay/order binding): SKIPPED — not testable."
    puts "      foodelivery's cart mandate has no order_id field; pay path is"
    puts "      disconnected from specific placed orders. A cross-principal"
    puts "      settle via a forged order reference cannot be constructed."
    puts "      Gap: no server-side check that cart.line_items correspond to"
    puts "      a placed order owned by the payer. Flagged for follow-up review."

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
    Self-discovery proof (P3 Task 2) — verifies the schema verb over HTTP.

    Boots the server, registers a fresh agent, calls:
      GET /kiosk/schema

    Asserts:
      • schema.verbs includes query/run/pay/schema and NOT events
      • schema.queries includes my_orders with a description
      • schema.actions includes place_order with a description

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-foodelivery-schema.log"

    host = begin
      addr = Resolv.getaddress("foodelivery.app") rescue ""
      addr == "127.0.0.1" ? "foodelivery.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting foodelivery (schema proof) on #{server_url} ──"

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

    verbs   = result["schema_verbs"]   || []
    queries = result["schema_queries"] || []
    actions = result["schema_actions"] || []

    # Verbs: query/run/pay/schema present; events absent
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

    # my_orders present with a description
    my_orders_entry = queries.find { |q| q["name"] == "my_orders" }
    if my_orders_entry
      puts "  ✓  schema.queries includes my_orders"
      if my_orders_entry["description"] && !my_orders_entry["description"].to_s.empty?
        puts "  ✓  my_orders has description: #{my_orders_entry["description"].inspect}"
      else
        failures << "my_orders missing description"
        puts "  ✗  my_orders missing description"
      end
    else
      failures << "schema.queries missing my_orders"
      puts "  ✗  schema.queries missing my_orders"
    end

    # place_order present with a description
    place_order_entry = actions.find { |a| a["name"] == "place_order" }
    if place_order_entry
      puts "  ✓  schema.actions includes place_order"
      if place_order_entry["description"] && !place_order_entry["description"].to_s.empty?
        puts "  ✓  place_order has description: #{place_order_entry["description"].inspect}"
      else
        failures << "place_order missing description"
        puts "  ✗  place_order missing description"
      end
    else
      failures << "schema.actions missing place_order"
      puts "  ✗  schema.actions missing place_order"
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
    Adversarial regression battery (R3 Phase 2 Task 3) — kiosk-redteam.

    Boots foodelivery, runs all generic Kiosk::Redteam scenarios and asserts
    each applicable attack is BLOCKED:

      BLOCKED  CrossTenantRead    — B's my_orders must not include A's orders
      BLOCKED  ForgedUserId       — agent-supplied user_id arg must be ignored
      BLOCKED  MandatePrincipalSwap — B signs a mandate with A's identity; rejected
      BLOCKED  MandateReplay      — B re-submits A's signed mandate JWS; rejected
      BLOCKED  TokenTampering     — altered JWT (claim flipped) rejected 401

    Scenarios that require a surface foodelivery does not expose SKIP cleanly:
      SKIPPED  UnpaidGatedAction, SpentResourceReuse, PayForOtherUseSelf
               (no gated_action configured)
      SKIPPED  MissingKyc, ExpiredKyc, ForgedKyc  (requires_kyc: false)

    Note: RegistrationWithoutPow is not run — foodelivery has no registration
    PoW gate (pow_difficulty: 0). skooti covers that scenario via d=20.
    Exec-time PoW redteam is a future enhancement.

    Exits 0 when all applicable scenarios are BLOCKED; exits 1 on any BREACH.
    A BREACH = a real hole in foodelivery — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-foodelivery-redteam.log"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = Resolv.getaddress("foodelivery.app") rescue ""
      addr == "127.0.0.1" ? "foodelivery.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting foodelivery (redteam battery) on #{server_url} ──"

    # ── boot the server ────────────────────────────────────────────────
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

    # ── wait for readiness ─────────────────────────────────────────────
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

    # ── run redteam_suite.rb ───────────────────────────────────────────
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

desc "End-to-end Kiosk demo: setup the DB then run the no-human order end-to-end."
task demo: ["demo:setup", "demo:order"]
