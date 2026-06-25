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

    pm_id = pay.dig("value", "payment_mandate_id")
    if pm_id && !pm_id.empty?
      puts "  ✓  pay.value.payment_mandate_id present (#{pm_id})"
    else
      failures << "pay.value.payment_mandate_id missing"
      puts "  ✗  pay.value.payment_mandate_id missing"
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

    pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates' 2>&1`.strip
    if pm_count == "1"
      puts "  ✓  kiosk.payment_mandates count = 1"
    else
      failures << "kiosk.payment_mandates COUNT expected 1, got #{pm_count.inspect}"
      puts "  ✗  kiosk.payment_mandates COUNT expected 1, got #{pm_count.inspect}"
    end

    # ── query-verb assertions ──────────────────────────────────────────────
    # QA1: query menu_by_restaurant — proves agent browses via named query, not SQL.
    # QA2: query my_orders (before extra order) — empty for the fresh second principal.
    # QA3: query my_orders (after extra order) — exactly 1 row, scoped to that principal.
    # These run against the same running server (already up from order_flow.rb run above).
    puts "\n── Query-verb assertions ──"

    q_post = lambda do |path, body_hash, bearer = ""|
      uri = URI("#{server_url}#{path}")
      req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json", "Authorization" => "Bearer #{bearer}" })
      req.body = JSON.generate(body_hash)
      res = Net::HTTP.new(uri.host, uri.port).request(req)
      [res.code.to_i, (JSON.parse(res.body) rescue {})]
    end

    # Register a second fresh agent (different principal — proves per-user scoping).
    q_key = OpenSSL::PKey::RSA.generate(2048)
    q_reg_rc, q_reg = q_post.call(
      "/kiosk/agents/register",
      { name: "hermes-qa", public_key: q_key.public_key.to_pem, role: "customer" },
    )
    if q_reg_rc == 201
      q_token   = q_reg["access_token"]
      q_user_id = q_reg["user_id"]

      # QA1: query menu_by_restaurant — Margherita must be present.
      qa1_rc, qa1_resp = q_post.call(
        "/kiosk/exec",
        { command: "query", body: { name: "menu_by_restaurant", restaurant: "Mamma Pizza" } },
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
        "/kiosk/exec",
        { command: "query", body: { name: "my_orders" } },
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
          "/kiosk/exec",
          {
            command: "run",
            body: {
              name:             "place_order",
              menu_item_id:     qa_menu_item_id,
              quantity:         1,
              delivery_address: "2 Query St, Istanbul",
            },
          },
          q_token,
        )
        if qa_place_rc == 200
          qa_order_id = qa_place.dig("value", "order_id")
          puts "  Placed QA order: #{qa_order_id}"

          # QA3: query my_orders after placing — exactly 1 row, this principal only.
          qa3_rc, qa3_resp = q_post.call(
            "/kiosk/exec",
            { command: "query", body: { name: "my_orders" } },
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
end

desc "End-to-end Kiosk demo: setup the DB then run the no-human order end-to-end."
task demo: ["demo:setup", "demo:order"]
