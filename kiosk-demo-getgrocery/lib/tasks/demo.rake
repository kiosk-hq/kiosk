# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-getgrocery.
# Tasks:
#   rake demo:setup   idempotent db:drop / create / migrate / seed
#   rake demo:shop    boots the server, runs getgrocery_flow.rb, asserts happy path
#   rake demo         setup + shop (full end-to-end proof)

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

  desc "Boot the server, run getgrocery_flow.rb end-to-end (no-human happy path), assert."
  task :shop do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port         = ENV.fetch("PORT", "3005")
    log          = "/tmp/kiosk-getgrocery-demo.log"
    db           = "kiosk_getgrocery_development"
    flow_rb      = File.expand_path("../../getgrocery_flow.rb", __dir__)
    failures     = []

    # -- host resolution --
    host = begin
      addr = begin
        Resolv.getaddress("getgrocery.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 getgrocery.app -- using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n-- Starting getgrocery on #{server_url} --"

    # -- boot the server --
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

    # -- wait for readiness --
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
    abort "Server did not become ready -- see #{log}" unless ready
    puts "  Server up at #{server_url}"

    # -- run getgrocery_flow.rb --
    puts "\n-- Running getgrocery_flow.rb --"
    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"
    raw     = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "getgrocery_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    # -- assertions: HTTP status --
    puts "\n-- Assertions --"

    check = lambda do |label, actual, expected|
      if actual == expected
        puts "  OK  #{label} == #{expected}"
      else
        failures << "#{label} expected #{expected}, got #{actual.inspect}"
        puts "  FAIL  #{label} expected #{expected}, got #{actual.inspect}"
      end
    end

    check.call("http_register",         result["http_register"],         201)
    check.call("http_stores",           result["http_stores"],           200)
    check.call("http_products",         result["http_products"],         200)
    check.call("http_add_to_cart",      result["http_add_to_cart"],      200)
    check.call("http_add_oos",          result["http_add_oos"],          200)
    check.call("http_sub_options",      result["http_sub_options"],      200)
    check.call("http_apply_sub",        result["http_apply_sub"],        200)
    check.call("http_delivery_slots",   result["http_delivery_slots"],   200)
    check.call("http_confirm_delivery", result["http_confirm_delivery"], 200)
    check.call("http_pay",              result["http_pay"],              200)

    # Delivery ID present
    did = result["delivery_id"]
    if did && !did.to_s.empty?
      puts "  OK  delivery_id present (#{did})"
    else
      failures << "delivery_id missing or empty"
      puts "  FAIL  delivery_id missing or empty"
    end

    # Scheduled_at present
    sat = result["scheduled_at"]
    if sat && !sat.to_s.empty?
      puts "  OK  scheduled_at present (#{sat})"
    else
      failures << "scheduled_at missing or empty"
      puts "  FAIL  scheduled_at missing or empty"
    end

    # Substitution accepted
    if result["substitution_accepted"] == true
      puts "  OK  substitution_accepted == true"
    else
      failures << "substitution_accepted expected true, got #{result["substitution_accepted"].inspect}"
      puts "  FAIL  substitution_accepted expected true, got #{result["substitution_accepted"].inspect}"
    end

    # pay.ok == true
    pay = result["pay"] || {}
    if pay["ok"] == true
      puts "  OK  pay.ok == true"
    else
      failures << "pay.ok not true (got #{pay["ok"].inspect})"
      puts "  FAIL  pay.ok got #{pay["ok"].inspect}"
    end

    pm_id = pay.dig("value", "payment_mandate_id")
    if pm_id && !pm_id.to_s.empty?
      puts "  OK  pay.value.payment_mandate_id present (#{pm_id})"
    else
      failures << "pay.value.payment_mandate_id missing"
      puts "  FAIL  pay.value.payment_mandate_id missing"
    end

    # -- assertions: DB row counts --
    deliveries_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM deliveries' 2>&1`.strip
    if deliveries_count.to_i >= 1
      puts "  OK  deliveries count >= 1 (got #{deliveries_count})"
    else
      failures << "deliveries COUNT expected >= 1, got #{deliveries_count.inspect}"
      puts "  FAIL  deliveries COUNT expected >= 1, got #{deliveries_count.inspect}"
    end

    pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates' 2>&1`.strip
    if pm_count.to_i >= 1
      puts "  OK  kiosk.payment_mandates >= 1 (got #{pm_count})"
    else
      failures << "kiosk.payment_mandates COUNT expected >= 1, got #{pm_count.inspect}"
      puts "  FAIL  kiosk.payment_mandates COUNT expected >= 1, got #{pm_count.inspect}"
    end

    # Substituted cart_item in DB
    sub_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM cart_items WHERE substituted = true' 2>&1`.strip
    if sub_count.to_i >= 1
      puts "  OK  cart_items[substituted=true] >= 1 (got #{sub_count})"
    else
      failures << "cart_items[substituted=true] expected >= 1, got #{sub_count.inspect}"
      puts "  FAIL  cart_items[substituted=true] expected >= 1, got #{sub_count.inspect}"
    end

    # -- final verdict --
    if failures.empty?
      puts "\n  All assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end

  # ── demo:isolation ───────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial cross-tenant isolation test (R3 Phase 2 Task 4).

    Boots the server, runs isolation_flow.rb with two fresh principals (A and B),
    and asserts all cross-tenant denial properties including getgrocery's
    distinctive cart-ownership mutation gates:

      HEADLINE: B cannot apply_substitution on A's cart (cart-ownership gate)
      HEADLINE: B cannot confirm_delivery on A's cart (cart-ownership gate)
      Assertion 3: B's my_orders excludes A's delivery (cross-tenant read blocked)
      Assertion 4: B's my_orders includes own delivery (positive control)
      Assertion 5: B's my_orders still excludes A's delivery after positive control
      Assertion 6: A's my_orders excludes B's delivery
      Assertion 7: DB check — forged user_id in add_to_cart ignored (cart belongs to B)

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    port = ENV.fetch("PORT", "3005")
    log  = "/tmp/kiosk-getgrocery-isolation.log"
    db   = "kiosk_getgrocery_development"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("getgrocery.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 getgrocery.app -- using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting getgrocery (isolation test) on #{server_url} ──"

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
    puts "\n── Running isolation_flow.rb (adversarial cross-tenant + cart-ownership) ──"
    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"
    raw     = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "isolation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_b             = result["user_id_b"]
    delivery_id_a         = result["delivery_id_a"]
    delivery_id_b         = result["delivery_id_b"]
    cart_id_b_forged      = result["cart_id_b_forged"]
    b_apply_sub_status    = result["b_apply_sub_status"]
    b_confirm_on_a_status = result["b_confirm_on_a_status"]
    b_my_orders_before    = result["b_my_orders_before"] || []
    b_my_orders_after     = result["b_my_orders_after"]  || []
    a_my_orders_after     = result["a_my_orders_after"]  || []

    # ── HEADLINE: B cannot apply_substitution on A's cart ─────────────
    if b_apply_sub_status == 403
      puts "  ✓  HEADLINE: B cannot apply_substitution on A's cart (cart-ownership gate) → 403"
    else
      failures << "ISOLATION HOLE: B's apply_substitution on A's cart returned #{b_apply_sub_status} (expected 403)"
      puts "  ✗  HEADLINE: apply_substitution ownership gate FAILED — returned #{b_apply_sub_status}"
    end

    # ── HEADLINE: B cannot confirm_delivery on A's cart ───────────────
    if b_confirm_on_a_status == 403
      puts "  ✓  HEADLINE: B cannot confirm_delivery on A's cart (cart-ownership gate) → 403"
    else
      failures << "ISOLATION HOLE: B's confirm_delivery on A's cart returned #{b_confirm_on_a_status} (expected 403)"
      puts "  ✗  HEADLINE: confirm_delivery ownership gate FAILED — returned #{b_confirm_on_a_status}"
    end

    # ── Assertion 3: B's my_orders (before) excludes A's delivery ─────
    if b_my_orders_before.include?(delivery_id_a)
      failures << "ISOLATION HOLE: B's my_orders (before) contains A's delivery #{delivery_id_a} — cross-tenant leak"
      puts "  ✗  Assertion 3 FAILED: B sees A's delivery #{delivery_id_a} — isolation hole"
    else
      puts "  ✓  Assertion 3: B's my_orders excludes A's delivery #{delivery_id_a} (cross-tenant read blocked)"
    end

    # ── Assertion 4: B's my_orders (after) includes own delivery ──────
    if b_my_orders_after.include?(delivery_id_b)
      puts "  ✓  Assertion 4: B's my_orders includes own delivery #{delivery_id_b} (positive control)"
    else
      failures << "B's my_orders does not contain own delivery #{delivery_id_b}; got #{b_my_orders_after.inspect}"
      puts "  ✗  Assertion 4 FAILED: B's my_orders missing own delivery #{delivery_id_b}"
    end

    # ── Assertion 5: B's my_orders (after) still excludes A's delivery ─
    if b_my_orders_after.include?(delivery_id_a)
      failures << "ISOLATION HOLE: B's my_orders (after) contains A's delivery #{delivery_id_a} — cross-tenant leak"
      puts "  ✗  Assertion 5 FAILED: B sees A's delivery #{delivery_id_a} after positive control"
    else
      puts "  ✓  Assertion 5: B's my_orders still excludes A's delivery #{delivery_id_a}"
    end

    # ── Assertion 6: A's my_orders excludes B's delivery ──────────────
    if a_my_orders_after.include?(delivery_id_b)
      failures << "ISOLATION HOLE: A's my_orders contains B's delivery #{delivery_id_b} — cross-tenant leak"
      puts "  ✗  Assertion 6 FAILED: A sees B's delivery #{delivery_id_b} — isolation hole"
    else
      puts "  ✓  Assertion 6: A's my_orders excludes B's delivery #{delivery_id_b}"
    end

    # ── Assertion 7: DB user_id on forged cart is B's, not A's ────────
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM carts WHERE id = '#{cart_id_b_forged}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  ✓  Assertion 7: DB carts.user_id for forged cart == user_id_b (#{user_id_b}) — forged arg ignored"
    else
      failures << "ISOLATION HOLE or unexpected: DB carts.user_id for forged cart is #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  ✗  Assertion 7 FAILED: unexpected user_id #{db_user_id.inspect} for forged cart (expected B's)"
    end

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer isolation and cart-ownership gates hold."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:isolation ────────────────────────────────────────────────────────

  # ── demo:schema ──────────────────────────────────────────────────────────────
  desc <<~DESC
    Self-discovery proof (R3 Phase 2 Task 4) — verifies schema + help verbs over HTTP.

    Boots the server, registers a fresh agent, calls:
      POST /kiosk/exec { command: "schema" }
      POST /kiosk/exec { command: "help"   }

    Asserts:
      • schema.verbs includes query/run/pay/schema/help and NOT events
      • schema.queries includes my_orders with a description
      • schema.actions includes add_to_cart with a description
      • schema.actions includes apply_substitution with a description
      • schema.actions includes confirm_delivery with a description
      • help.text mentions my_orders, add_to_cart, apply_substitution, confirm_delivery

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3005")
    log  = "/tmp/kiosk-getgrocery-schema.log"

    host = begin
      addr = begin
        Resolv.getaddress("getgrocery.app")
      rescue Resolv::ResolvError
        ""
      end
      addr == "127.0.0.1" ? "getgrocery.app" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting getgrocery (schema/help proof) on #{server_url} ──"

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
    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"
    raw     = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
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

    # add_to_cart present in actions with a description
    add_to_cart_entry = actions.find { |a| a["name"] == "add_to_cart" }
    if add_to_cart_entry
      puts "  ✓  schema.actions includes add_to_cart"
      if add_to_cart_entry["description"] && !add_to_cart_entry["description"].to_s.empty?
        puts "  ✓  add_to_cart has description: #{add_to_cart_entry["description"].inspect}"
      else
        failures << "add_to_cart missing description"
        puts "  ✗  add_to_cart missing description"
      end
    else
      failures << "schema.actions missing add_to_cart"
      puts "  ✗  schema.actions missing add_to_cart"
    end

    # apply_substitution present with a description
    apply_sub_entry = actions.find { |a| a["name"] == "apply_substitution" }
    if apply_sub_entry
      puts "  ✓  schema.actions includes apply_substitution"
      if apply_sub_entry["description"] && !apply_sub_entry["description"].to_s.empty?
        puts "  ✓  apply_substitution has description: #{apply_sub_entry["description"].inspect}"
      else
        failures << "apply_substitution missing description"
        puts "  ✗  apply_substitution missing description"
      end
    else
      failures << "schema.actions missing apply_substitution"
      puts "  ✗  schema.actions missing apply_substitution"
    end

    # confirm_delivery present with a description
    confirm_entry = actions.find { |a| a["name"] == "confirm_delivery" }
    if confirm_entry
      puts "  ✓  schema.actions includes confirm_delivery"
      if confirm_entry["description"] && !confirm_entry["description"].to_s.empty?
        puts "  ✓  confirm_delivery has description: #{confirm_entry["description"].inspect}"
      else
        failures << "confirm_delivery missing description"
        puts "  ✗  confirm_delivery missing description"
      end
    else
      failures << "schema.actions missing confirm_delivery"
      puts "  ✗  schema.actions missing confirm_delivery"
    end

    # help text mentions all key action and query names
    %w[my_orders add_to_cart apply_substitution confirm_delivery].each do |name|
      if text.include?(name)
        puts "  ✓  help text mentions #{name}"
      else
        failures << "help text does not mention #{name}"
        puts "  ✗  help text does not mention #{name}"
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
  # ── end demo:schema ───────────────────────────────────────────────────────────

  # ── demo:redteam ─────────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery (R3 Phase 2 Task 4) — kiosk-redteam.

    Boots getgrocery, runs all generic Kiosk::Redteam scenarios and asserts
    each applicable attack is BLOCKED:

      BLOCKED  CrossTenantRead      — B's my_orders must not include A's deliveries
      BLOCKED  MandatePrincipalSwap — B signs a mandate with A's identity; rejected
      BLOCKED  MandateReplay        — B re-submits A's signed mandate JWS; rejected
      BLOCKED  TokenTampering       — altered JWT (claim flipped) rejected 401

    Scenarios that require a surface getgrocery does not expose SKIP cleanly:
      SKIPPED  ForgedUserId         — forge_action nil: add_to_cart returns cart_id
                                      but my_orders lists delivery ids; readback
                                      would be vacuously BLOCKED (entity mismatch).
                                      Real coverage: demo:isolation Assertion 7
                                      (DB SELECT confirms cart.user_id = caller's id).
      SKIPPED  UnpaidGatedAction, SpentResourceReuse, PayForOtherUseSelf
               (no gated_action — cart ownership is NOT a payment gate)
      SKIPPED  MissingKyc, ExpiredKyc, ForgedKyc  (requires_kyc: false)

    Note: RegistrationWithoutPow is not run — getgrocery has no registration
    PoW gate (pow_difficulty: 0).

    Exits 0 when all applicable scenarios are BLOCKED; exits 1 on any BREACH.
    A BREACH = a real hole in getgrocery — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    port = ENV.fetch("PORT", "3005")
    log  = "/tmp/kiosk-getgrocery-redteam.log"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("getgrocery.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 getgrocery.app -- using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting getgrocery (redteam battery) on #{server_url} ──"

    # ── boot the server ────────────────────────────────────────────────
    File.truncate(log, 0) if File.exist?(log)
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
      puts "  Server stopped."
    end

    # ── wait for readiness ─────────────────────────────────────────────
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
  # ── end demo:redteam ──────────────────────────────────────────────────────────
end

desc "End-to-end getgrocery demo: setup DB then run no-human cart->substitution->delivery."
task demo: ["demo:setup", "demo:shop"]
