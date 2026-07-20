# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-getgrocery.
# Tasks:
#   rake demo:setup      idempotent db:drop / create / migrate / seed
#   rake demo:shop       boots the server, runs getgrocery_flow.rb, asserts happy path
#   rake demo:claim      claim-rebind walkthrough: a standalone assistant's key is
#                        re-bound to the human's account, then pays with its saved card
#   rake demo:isolation  adversarial cross-tenant + order-ownership isolation test
#   rake demo:rls        opt-in Postgres RLS showcase — enforced-session three-way
#                        proof (rls_proof.rb) that a non-owner app_role is order-scoped
#   rake demo:schema     self-discovery proof over the schema verb
#   rake demo:redteam    adversarial regression battery (kiosk-redteam scenarios)
#   rake demo:pow        commerce catalog-toll PoW demo (catalog 402 → solve → 200)
#   rake demo            setup + shop (full end-to-end proof)

# Start (or reuse) a local stripe-mock; return its HTTP base URL. The adversarial
# suites use it so the full pay→settlement→gate flow runs with NO real Stripe
# (fast, no key, no charges, CI-runnable). demo:shop still uses real Stripe.
def start_stripe_mock
  require "socket"
  port = 12111
  url  = "http://127.0.0.1:#{port}"

  reachable = lambda do
    s = TCPSocket.new("127.0.0.1", port); s.close; true
  rescue StandardError
    false
  end

  return url if reachable.call # already running — reuse it

  unless system("command -v stripe-mock >/dev/null 2>&1")
    abort "stripe-mock not found. Install it: brew install stripe-mock"
  end

  pid = spawn("stripe-mock", out: "/tmp/stripe-mock.log", err: "/tmp/stripe-mock.log")
  at_exit do
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  30.times { return url if reachable.call; sleep 0.3 }
  abort "stripe-mock did not become ready on #{url} — see /tmp/stripe-mock.log"
end

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

  desc "Boot the server, run getgrocery_flow.rb end-to-end (no-human happy path: register→catalog→create_order→delivery_slots→payment_setup→pay→schedule_delivery→my_orders), assert."
  task :shop do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    # getgroceries uses the real Stripe adapter — no StubPsp. To run the
    # off_session charge you need EITHER a real Stripe test key (sk_test_…,
    # producing a genuine pi_ against Stripe test mode) OR — when no key is
    # present, e.g. in CI — a local stripe-mock, which returns shaped pi_
    # fixtures so the full flow runs secret-free (never inject keys
    # into CI). A real key takes precedence when set.
    use_mock = ENV["STRIPE_SECRET_KEY"].to_s.strip.empty?
    mock_url = use_mock ? start_stripe_mock : nil
    if use_mock
      puts "  (no STRIPE_SECRET_KEY — running against stripe-mock at #{mock_url}, no real charge)"
    end

    port         = ENV.fetch("PORT", "3005")
    log          = "/tmp/kiosk-getgrocery-demo.log"
    db           = ENV.fetch("KIOSK_GETGROCERY_DB", "kiosk_getgrocery_development")
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
    # KIOSK_TEST_AUTOCARD=1: the adapter simulates a completed SetupIntent so the
    # driver needs no card-setup step (real Stripe still produces a real pi_…).
    File.truncate(log, 0) if File.exist?(log)
    boot_env = { "KIOSK_ISSUER" => kiosk_issuer, "KIOSK_TEST_AUTOCARD" => "1" }
    if use_mock
      boot_env["STRIPE_MOCK_URL"]   = mock_url
      boot_env["STRIPE_SECRET_KEY"] = "sk_test_mock"
    end
    server_pid = spawn(
      boot_env,
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

    check.call("http_register",      result["http_register"],      201)
    check.call("http_catalog",       result["http_catalog"],       200)
    check.call("http_order",         result["http_order"],         200)
    check.call("http_slots",         result["http_slots"],         200)
    check.call("http_payment_setup", result["http_payment_setup"], 200)
    check.call("http_pay",           result["http_pay"],           200)
    check.call("http_schedule",      result["http_schedule"],      200)
    check.call("http_my_orders",     result["http_my_orders"],     200)

    # order_id present
    oid = result["order_id"]
    if oid && !oid.to_s.empty?
      puts "  OK  order_id present (#{oid})"
    else
      failures << "order_id missing or empty"
      puts "  FAIL  order_id missing or empty"
    end

    # scheduled_at present
    sat = result["scheduled_at"]
    if sat && !sat.to_s.empty?
      puts "  OK  scheduled_at present (#{sat})"
    else
      failures << "scheduled_at missing or empty"
      puts "  FAIL  scheduled_at missing or empty"
    end

    # pay.ok == true
    pay = result["pay"] || {}
    if pay["ok"] == true
      puts "  OK  pay.ok == true"
    else
      failures << "pay.ok not true (got #{pay["ok"].inspect})"
      puts "  FAIL  pay.ok got #{pay["ok"].inspect}"
    end

    pm_id = pay.dig("value", "settlement_id")
    if pm_id && !pm_id.to_s.empty?
      puts "  OK  pay.value.settlement_id present (#{pm_id})"
    else
      failures << "pay.value.settlement_id missing"
      puts "  FAIL  pay.value.settlement_id missing"
    end

    # psp_reference must start with pi_ — a real Stripe (or stripe-mock)
    # off_session PaymentIntent went through the adapter.
    psp_ref = result["psp_reference"].to_s
    if psp_ref.match?(/\Api_/)
      kind = use_mock ? "stripe-mock" : "real Stripe"
      puts "  OK  psp_reference is a #{kind} PaymentIntent (#{psp_ref})"
    else
      hint = use_mock ? "stripe-mock did not return a pi_ — see /tmp/stripe-mock.log" : "ensure STRIPE_SECRET_KEY is a real sk_test_… key"
      failures << "psp_reference expected /^pi_/, got #{psp_ref.inspect} — #{hint}"
      puts "  FAIL  psp_reference not a pi_… (got #{psp_ref.inspect})"
    end

    # -- assertions: DB row counts --
    orders_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM orders WHERE status = 'scheduled'" 2>&1`.strip
    if orders_count.to_i >= 1
      puts "  OK  orders[status=scheduled] count >= 1 (got #{orders_count})"
    else
      failures << "orders[status=scheduled] COUNT expected >= 1, got #{orders_count.inspect}"
      puts "  FAIL  orders[status=scheduled] COUNT expected >= 1, got #{orders_count.inspect}"
    end

    pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.settlements' 2>&1`.strip
    if pm_count.to_i >= 1
      puts "  OK  kiosk.settlements >= 1 (got #{pm_count})"
    else
      failures << "kiosk.settlements COUNT expected >= 1, got #{pm_count.inspect}"
      puts "  FAIL  kiosk.settlements COUNT expected >= 1, got #{pm_count.inspect}"
    end

    items_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM order_items' 2>&1`.strip
    if items_count.to_i >= 1
      puts "  OK  order_items count >= 1 (got #{items_count})"
    else
      failures << "order_items COUNT expected >= 1, got #{items_count.inspect}"
      puts "  FAIL  order_items COUNT expected >= 1, got #{items_count.inspect}"
    end

    # my_orders contains own order_id
    my_orders = result["my_orders"] || []
    if my_orders.any? { |o| o["id"] == result["order_id"] }
      puts "  OK  my_orders contains own order #{result["order_id"]}"
    else
      failures << "my_orders does not contain order_id #{result["order_id"].inspect}"
      puts "  FAIL  my_orders does not contain order_id #{result["order_id"].inspect}"
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

  # ── demo:claim ───────────────────────────────────────────────────────────────
  desc <<~DESC
    Claim-rebind walkthrough — "why not MY account?".

    Boots the server against stripe-mock (the walkthrough charges a SEEDED
    card-on-file mapping — a mock fixture, no real key, no real charge; run
    demo:shop for the real-Stripe path) and runs claim_flow.rb:

      1. A standalone assistant self-registers (fresh key, own synthetic
         account), orders groceries, and hits payment_setup → setup_required
         (no card on file).
      2. The human says "use MY account": the claim ceremony runs with the
         EXISTING key — verify-page approval (stub session channel) +
         possession-proof token poll — and REBINDS it: agent_id stays,
         user_id remaps to the seeded human, reputation carries. The old
         standalone order is NOT migrated (no assistant_claimed hook here).
      3. A NEW order as the human: payment_setup → ready (the seeded saved
         card), pay settles off_session against it.

    Exits 0 if all assertions hold; exits 1 on failure.
  DESC
  task :claim do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"
    require "shellwords"

    mock_url = start_stripe_mock
    ENV["STRIPE_MOCK_URL"]   = mock_url
    ENV["STRIPE_SECRET_KEY"] = "sk_test_mock" if ENV["STRIPE_SECRET_KEY"].to_s.empty?
    puts "  (stripe-mock at #{mock_url} — seeded saved-card fixture, no real Stripe)"
    Rake::Task["demo:setup"].invoke

    port = ENV.fetch("PORT", "3005")
    log  = "/tmp/kiosk-getgrocery-claim.log"
    db   = ENV.fetch("KIOSK_GETGROCERY_DB", "kiosk_getgrocery_development")

    # The seeded account holder with the saved card (db/seeds.rb).
    human_id     = "00000000-0000-0000-0000-000000000042"
    human_cus_id = "cus_getgrocery_saved_card"

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
    failures     = []

    puts "\n── Starting getgrocery (claim-rebind walkthrough) on #{server_url} ──"

    # ── boot the server ────────────────────────────────────────────────
    # NO KIOSK_TEST_AUTOCARD: the standalone account must genuinely get
    # setup_required, and the human's "ready" must come from the seeded
    # card mapping — the contrast is the point of the walkthrough.
    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => kiosk_issuer, "STRIPE_MOCK_URL" => mock_url, "STRIPE_SECRET_KEY" => "sk_test_mock" },
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

    # ── run claim_flow.rb ──────────────────────────────────────────────
    flow_rb = File.expand_path("../../claim_flow.rb", __dir__)
    puts "\n── Running claim_flow.rb ──"
    env_str = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape} " \
              "HUMAN_USER_ID=#{human_id.shellescape}"
    raw = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
    json_line = raw.lines.grep(/^\{/).last
    puts raw.lines.reject { |l| l.start_with?("{") }.join
    puts json_line if json_line
    result = JSON.parse(json_line || raw) rescue abort("claim_flow.rb produced no JSON:\n#{raw}")

    puts "\n══ Claim-rebind assertions ══"
    check = lambda do |label, ok|
      if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
    end
    check.call("standalone register → 201",                        result["http_register"] == 201)
    check.call("standalone payment_setup → setup_required (no card)", result["standalone_payment_setup"] == [200, "setup_required"])
    check.call("device_authorization carries the RFC 8628 fields",  result["da_fields"] == true)
    check.call("human approve on the verify page → 200",            result["approve"] == 200)
    check.call("REBIND: agent_id stable across the claim",          result["agent_id_stable"] == true)
    check.call("REBIND: user_id remapped to the human",             result["rebound_user"] == true)
    check.call("standalone order NOT migrated to the human",        result["standalone_order_not_migrated"] == true)
    check.call("human payment_setup → ready (saved card)",          result["human_payment_setup"] == [200, "ready"])
    check.call("pay with the saved card → 200",                     result["http_pay"] == 200)
    check.call("psp_reference is a stripe-mock PaymentIntent (pi_…)", result["psp_reference"].to_s.start_with?("pi_"))
    check.call("human's my_orders contains the new order",          result["human_sees_new_order"] == true)

    # ── DB ground truth ────────────────────────────────────────────────
    agent_id = result["agent_id"].to_s
    bound_uid = `psql -X -d #{db} -tAc "SELECT user_id FROM kiosk.agents WHERE id = '#{agent_id}'" 2>&1`.strip
    check.call("DB kiosk.agents.user_id for the key == the human (#{human_id})", bound_uid == human_id)
    settle_uid = `psql -X -d #{db} -tAc "SELECT user_id FROM kiosk.settlements ORDER BY settled_at DESC LIMIT 1" 2>&1`.strip
    check.call("DB settlement charged the human's account",         settle_uid == human_id)
    human_cus = `psql -X -d #{db} -tAc "SELECT customer_id FROM stripe_customers WHERE user_id = '#{human_id}'" 2>&1`.strip
    check.call("DB the human's card mapping is still the SEEDED one (#{human_cus_id})", human_cus == human_cus_id)
    standalone_uid = `psql -X -d #{db} -tAc "SELECT user_id FROM orders WHERE id = '#{result["standalone_order_id"]}'" 2>&1`.strip
    check.call("DB the standalone order still belongs to the standalone account", standalone_uid == result["standalone_user_id"])

    if failures.empty?
      puts "\n  All claim-rebind assertions PASSED."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:claim ────────────────────────────────────────────────────────────

  # ── demo:isolation ───────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial cross-tenant isolation test.

    Boots the server, runs isolation_flow.rb with two fresh principals (A and B),
    and asserts all cross-tenant denial properties including getgrocery's
    distinctive order-ownership mutation gates:

      HEADLINE: B cannot schedule_delivery on A's order (order-ownership gate)
      Assertion 1: B's my_orders excludes A's order (cross-tenant read blocked)
      Assertion 2: B's my_orders includes own order (positive control)
      Assertion 3: B's my_orders still excludes A's order after positive control
      Assertion 4: A's my_orders excludes B's order
      Assertion 5: DB orders.user_id for forged order == B (forged arg ignored)

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    # Adversarial suite → stripe-mock (no real charges, no key). The gates being
    # tested are pure Kiosk logic; Stripe is only the settlement rail, so a mock
    # exercises the full flow end-to-end.
    mock_url = start_stripe_mock
    puts "  (stripe-mock at #{mock_url} — adversarial suite, no real Stripe)"

    port = ENV.fetch("PORT", "3005")
    log  = "/tmp/kiosk-getgrocery-isolation.log"
    db   = ENV.fetch("KIOSK_GETGROCERY_DB", "kiosk_getgrocery_development")

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
      { "KIOSK_ISSUER" => kiosk_issuer, "STRIPE_MOCK_URL" => mock_url, "STRIPE_SECRET_KEY" => "sk_test_mock", "KIOSK_TEST_AUTOCARD" => "1" },
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
    puts "\n── Running isolation_flow.rb (adversarial cross-tenant + order-ownership) ──"
    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"
    raw     = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "isolation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    user_id_b              = result["user_id_b"]
    order_id_a             = result["order_id_a"]
    order_id_b             = result["order_id_b"]
    order_id_b_forged      = result["order_id_b_forged"]
    b_schedule_on_a_status = result["b_schedule_on_a_status"]
    b_my_orders_before     = result["b_my_orders_before"] || []
    b_my_orders_after      = result["b_my_orders_after"]  || []
    a_my_orders_after      = result["a_my_orders_after"]  || []

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    # HEADLINE: B cannot schedule_delivery on A's order (order-ownership gate)
    if b_schedule_on_a_status == 403
      puts "  ✓  HEADLINE: B cannot schedule_delivery on A's order (order-ownership gate) → 403"
    else
      failures << "ISOLATION HOLE: B's schedule_delivery on A's order returned #{b_schedule_on_a_status} (expected 403)"
      puts "  ✗  HEADLINE: schedule_delivery ownership gate FAILED — returned #{b_schedule_on_a_status}"
    end

    # Assertion 1: B's my_orders (before) excludes A's order
    if b_my_orders_before.include?(order_id_a)
      failures << "ISOLATION HOLE: B's my_orders (before) contains A's order #{order_id_a} — cross-tenant leak"
      puts "  ✗  Assertion 1 FAILED: B sees A's order #{order_id_a} — isolation hole"
    else
      puts "  ✓  Assertion 1: B's my_orders excludes A's order #{order_id_a} (cross-tenant read blocked)"
    end

    # Assertion 2: B's my_orders (after) includes own order (positive control)
    if b_my_orders_after.include?(order_id_b)
      puts "  ✓  Assertion 2: B's my_orders includes own order #{order_id_b} (positive control)"
    else
      failures << "B's my_orders does not contain own order #{order_id_b}; got #{b_my_orders_after.inspect}"
      puts "  ✗  Assertion 2 FAILED: B's my_orders missing own order #{order_id_b}"
    end

    # Assertion 3: B's my_orders (after) still excludes A's order
    if b_my_orders_after.include?(order_id_a)
      failures << "ISOLATION HOLE: B's my_orders (after) contains A's order #{order_id_a} — cross-tenant leak"
      puts "  ✗  Assertion 3 FAILED: B sees A's order #{order_id_a} after positive control"
    else
      puts "  ✓  Assertion 3: B's my_orders still excludes A's order #{order_id_a}"
    end

    # Assertion 4: A's my_orders excludes B's order
    if a_my_orders_after.include?(order_id_b)
      failures << "ISOLATION HOLE: A's my_orders contains B's order #{order_id_b} — cross-tenant leak"
      puts "  ✗  Assertion 4 FAILED: A sees B's order #{order_id_b} — isolation hole"
    else
      puts "  ✓  Assertion 4: A's my_orders excludes B's order #{order_id_b}"
    end

    # Assertion 5: DB — forged user_id in create_order ignored (order.user_id = B's)
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM orders WHERE id = '#{order_id_b_forged}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  ✓  Assertion 5: DB orders.user_id for forged order == user_id_b (#{user_id_b}) — forged arg ignored"
    else
      failures << "ISOLATION HOLE or unexpected: DB orders.user_id for forged order is #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  ✗  Assertion 5 FAILED: unexpected user_id #{db_user_id.inspect} for forged order (expected B's)"
    end

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer isolation and order-ownership gates hold."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:isolation ────────────────────────────────────────────────────────

  # ── demo:schema ──────────────────────────────────────────────────────────────
  desc <<~DESC
    Self-discovery proof — verifies the schema verb over HTTP.

    Boots the server, registers a fresh agent, calls:
      GET /kiosk/schema

    Asserts:
      • schema.verbs includes query/run/pay/schema and NOT events
      • schema.queries includes catalog, delivery_slots, my_orders (each with description)
      • schema.actions includes create_order, schedule_delivery (each with description)
      • schema.queries does NOT include stores, products_by_store, substitution_options
      • schema.actions does NOT include add_to_cart, apply_substitution, confirm_delivery

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

    puts "\n── Starting getgrocery (schema proof) on #{server_url} ──"

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

    # queries present with descriptions: catalog, delivery_slots, my_orders
    %w[catalog delivery_slots my_orders].each do |qname|
      entry = queries.find { |q| q["name"] == qname }
      if entry
        puts "  ✓  schema.queries includes #{qname}"
        if entry["description"] && !entry["description"].to_s.empty?
          puts "  ✓  #{qname} has description: #{entry["description"].inspect}"
        else
          failures << "#{qname} missing description"
          puts "  ✗  #{qname} missing description"
        end
      else
        failures << "schema.queries missing #{qname}"
        puts "  ✗  schema.queries missing #{qname}"
      end
    end

    # actions present with descriptions: create_order, schedule_delivery
    %w[create_order schedule_delivery].each do |aname|
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

    # queries must NOT include old names
    %w[stores products_by_store substitution_options].each do |qname|
      if queries.any? { |q| q["name"] == qname }
        failures << "schema.queries must NOT include #{qname} (old surface)"
        puts "  ✗  schema.queries must NOT include #{qname}"
      else
        puts "  ✓  schema.queries does not include #{qname} (old surface absent)"
      end
    end

    # actions must NOT include old names
    %w[add_to_cart apply_substitution confirm_delivery].each do |aname|
      if actions.any? { |a| a["name"] == aname }
        failures << "schema.actions must NOT include #{aname} (old surface)"
        puts "  ✗  schema.actions must NOT include #{aname}"
      else
        puts "  ✓  schema.actions does not include #{aname} (old surface absent)"
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
  # ── end demo:schema ───────────────────────────────────────────────────────────

  # ── demo:redteam ─────────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery — kiosk-redteam.

    Boots getgrocery, runs all generic Kiosk::Redteam scenarios and asserts
    each applicable attack is BLOCKED (9 BLOCKED, 3 SKIPPED):

      BLOCKED  CrossTenantRead        — B's my_orders must not include A's orders
      BLOCKED  ForgedUserId           — forged user_id in create_order ignored; order stays B's
      BLOCKED  UnpaidGatedAction      — schedule_delivery without a settled mandate rejected
      BLOCKED  SpentResourceReuse     — a mandate already settled cannot be reused
      BLOCKED  PayForOtherUseSelf     — mandate paid for one order cannot gate another
      BLOCKED  MandatePrincipalSwap   — B signs a mandate with A's identity; rejected
      BLOCKED  MandateReplay          — B re-submits A's signed mandate JWS; rejected
      BLOCKED  TokenTampering         — altered JWT (claim flipped) rejected 401
      BLOCKED  PrivilegeSelfSelection — agent cannot self-assign elevated privilege

    Scenarios that require a surface getgrocery does not expose SKIP cleanly:
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

    # getgroceries uses the real Stripe adapter (no StubPsp).
    # Adversarial battery → stripe-mock (no real charges, no key). The gates
    # under test are pure Kiosk logic; Stripe is only the settlement rail.
    mock_url = start_stripe_mock
    puts "  (stripe-mock at #{mock_url} — adversarial battery, no real Stripe)"

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
    env_vars = { "KIOSK_ISSUER" => kiosk_issuer, "STRIPE_MOCK_URL" => mock_url, "STRIPE_SECRET_KEY" => "sk_test_mock", "KIOSK_TEST_AUTOCARD" => "1" }

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

desc "End-to-end getgrocery demo: setup DB then run no-human catalog->create_order->pay->schedule_delivery."
task demo: ["demo:setup", "demo:shop"]

namespace :demo do
  desc <<~DESC
    Commerce catalog-toll PoW demo (KIOSK_POW_DEMO=1).

    Boots the server with the catalog gate active and runs pow_flow.rb:
    catalog query → 402 equihash → solve.py → 200; wrong nonce → 403 + penalty.
    Requires python3 + numpy.
  DESC
  task :pow do
    require "net/http"; require "uri"; require "json"; require "shellwords"

    abort "numpy not found (pip install numpy)" unless system("python3 -c 'import numpy' 2>/dev/null")

    # The catalog-toll flow never pays; default a dummy Stripe test key so the
    # initializer boots (setup + server) without a real key or stripe-mock.
    ENV["STRIPE_SECRET_KEY"] = "sk_test_dummy" if ENV["STRIPE_SECRET_KEY"].to_s.empty?
    Rake::Task["demo:setup"].invoke

    port         = ENV.fetch("PORT", "3005")
    server_url   = "http://127.0.0.1:#{port}"
    log          = "/tmp/kiosk-getgrocery-pow.log"
    flow_rb      = File.expand_path("../../pow_flow.rb", __dir__)
    failures     = []

    # The catalog-toll flow never pays, so a dummy test key is enough to boot the
    # Stripe adapter (no API call is made). Real key / stripe-mock is only needed
    # for the payment demos (demo:shop).
    stripe_key = ENV["STRIPE_SECRET_KEY"].to_s.empty? ? "sk_test_dummy" : ENV["STRIPE_SECRET_KEY"]

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => server_url, "KIOSK_POW_DEMO" => "1",
        "KIOSK_TEST_AUTOCARD" => "1", "STRIPE_SECRET_KEY" => stripe_key },
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
      puts "  Server up at #{server_url} (catalog PoW active)"

      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{server_url.shellescape}"
      raw = `#{env} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      json_line = raw.lines.grep(/^\{/).last
      puts raw.lines.reject { |l| l.start_with?("{") }.join
      puts json_line if json_line
      result = JSON.parse(json_line || raw) rescue abort("pow_flow.rb produced no JSON:\n#{raw}")

      puts "\n══ Catalog PoW assertions ══"
      check = lambda do |label, ok|
        if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
      end
      check.call("catalog challenged (402)",         result["http_challenge"] == 402)
      check.call("served after solve (200 + rows)",  result["served"] == true && result["catalog_rows"].to_i >= 1)
      check.call("wrong nonce rejected (403)",       result["http_wrong_nonce"] == 403)
      check.call("on_bad_proof penalized",           result["bad_proof_count"].to_i >= 1)
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All catalog PoW assertions PASSED."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end

  # ── demo:rls — additive RLS-enforce reference (the suite's RLS showcase) ────
  desc <<~DESC
    RLS enforce reference — strictly additive overlay; does NOT touch the
    structure.sql schema and does NOT add any migration.

    This is the suite's single RLS *showcase*: it demonstrates the opt-in RLS
    data plane on getgrocery's owner-scoped `orders` table.

    Loads the normal schema (db:drop → db:create → db:schema:load → db:seed —
    identical to demo:setup), then applies RLS as an IMPERATIVE OVERLAY via the
    kiosk-rls gem (Kiosk::RLS::Emitter — dogfooded).

    Role model:
      kiosk_getgrocery_app  NOLOGIN NOSUPERUSER NOBYPASSRLS   ← non-owner, subject to RLS
      GRANT kiosk_getgrocery_app TO CURRENT_USER              ← allows SET LOCAL ROLE

    Initializer gate (KIOSK_RLS_ENFORCE=1):
      c.enforce_db_role = true
      c.app_role        = "kiosk_getgrocery_app"
    SessionContext.open appends SET LOCAL ROLE "kiosk_getgrocery_app" after GUCs.

    Three-way proof (rls_proof.rb):
      1. Negative control: owner/superuser WITHOUT SessionContext sees BOTH rows
         (superuser bypasses RLS — the pre-fix no-op / leak).
      2. Enforced session for A: raw unscoped SELECT * FROM orders → only A's row.
      3. Enforced session for B: raw unscoped SELECT * FROM orders → only B's row.

    Exits 0 if all three assertions pass; exits 1 on any failure. The default
    shop path is completely unaffected: structure.sql unchanged, no migration added.
  DESC
  task :rls do
    # getgrocery's initializer requires a Stripe key to boot; the RLS proof
    # never pays, so default a dummy test key (same as demo:pow).
    ENV["STRIPE_SECRET_KEY"] = "sk_test_dummy" if ENV["STRIPE_SECRET_KEY"].to_s.empty?

    # ── Step 1: Load structure.sql — identical to demo:setup (canonical) ─────
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"

    # ── Step 2: Create the non-owner app role (idempotent) ──────────────────
    # NOLOGIN: cannot connect directly — only reachable via SET LOCAL ROLE.
    # NOSUPERUSER: does not bypass RLS (unlike the login/owner role).
    # NOBYPASSRLS: explicitly subject to all RLS policies.
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_getgrocery_app') " \
       "THEN CREATE ROLE kiosk_getgrocery_app NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF; " \
       "END \\$\\$;\" >/dev/null"
    puts "  Role kiosk_getgrocery_app ensured (NOLOGIN NOSUPERUSER NOBYPASSRLS)."

    # ── Step 3: Grant kiosk_getgrocery_app to CURRENT_USER ──────────────────
    # Required so that the owner session can execute SET LOCAL ROLE inside a
    # transaction (SET ROLE requires membership).
    sh "psql -d postgres -tAc 'GRANT kiosk_getgrocery_app TO CURRENT_USER' >/dev/null"
    puts "  GRANT kiosk_getgrocery_app TO CURRENT_USER — SET LOCAL ROLE now available."

    # ── Step 4: Apply RLS overlay via kiosk-rls Emitter (dogfooded) ─────────
    # Run WITHOUT KIOSK_RLS_ENFORCE — overlay setup is privileged (owner connection).
    overlay_rb = File.expand_path("../../rls_overlay.rb", __dir__)
    puts "\n── Applying RLS overlay ──"
    sh "bundle exec rails runner #{overlay_rb}"

    # ── Step 5: Run the three-way isolation proof (KIOSK_RLS_ENFORCE=1) ─────
    proof_rb = File.expand_path("../../rls_proof.rb", __dir__)
    puts "\n── Running RLS isolation proof (KIOSK_RLS_ENFORCE=1) ──"
    raw = `KIOSK_RLS_ENFORCE=1 bundle exec rails runner #{proof_rb} 2>&1`
    puts raw

    require "json"
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
      puts "  structure.sql is unchanged; default shop path unaffected."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:rls ──────────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:telemetry ─────────────────────────────────────────────────────────
  desc <<~DESC
    Live-activity telemetry demo (T-032 §4). Seeds simulated events into the
    (shared) telemetry store and prints the privacy-safe aggregate — the JSON
    the /demo/activity.json endpoint and the kiosk.tech landing tile return,
    BEFORE any real deploy traffic. Sets KIOSK_TELEMETRY=1 for this process.

      rake demo:telemetry            # 40 events / 8 agents, then print aggregate
      EVENTS=100 AGENTS=20 rake demo:telemetry

    No server boot; talks to the telemetry store directly (the demo's own DB
    locally, or KIOSK_TELEMETRY_DB_URL if the shared hosted DB is set).
  DESC
  task telemetry: :environment do
    ENV["KIOSK_TELEMETRY"] ||= "1"
    require Rails.root.join("lib/demo_telemetry")

    events = (ENV["EVENTS"] || 40).to_i
    agents = (ENV["AGENTS"] || 8).to_i

    puts "\n── Seeding #{events} simulated events across #{agents} agents (app=#{DemoTelemetry.app_name}) ──"
    written = DemoTelemetry.simulate!(events: events, agents: agents)
    puts "  wrote #{written} rows into #{DemoTelemetry::TABLE}"

    puts "\n── Aggregate (scope=this app) — what GET /demo/activity.json?scope=app returns ──"
    puts JSON.pretty_generate(DemoTelemetry.aggregates(app: DemoTelemetry.app_name))

    puts "\n── Aggregate (scope=all) — what the kiosk.tech landing tile fetches ──"
    puts JSON.pretty_generate(DemoTelemetry.aggregates(app: nil))

    agg = DemoTelemetry.aggregates(app: DemoTelemetry.app_name)
    if agg[:assistants_active_10m].to_i > 0 && agg[:registered_total].to_i > 0
      puts "\n  OK  telemetry aggregate populated (active #{agg[:assistants_active_10m]}, registered #{agg[:registered_total]})."
    else
      puts "\n  FAIL  telemetry aggregate empty after seeding — #{agg.inspect}"
      exit 1
    end
  end
  # ── end demo:telemetry ─────────────────────────────────────────────────────
end
