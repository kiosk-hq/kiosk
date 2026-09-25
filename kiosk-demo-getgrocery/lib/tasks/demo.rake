# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-getgrocery.
# Tasks:
#   rake demo:setup      idempotent db:drop / create / schema:load / seed
#   rake check:shop       boots the server, runs script/getgrocery_flow.rb, asserts happy path
#   rake check:claim      claim-rebind walkthrough: a standalone assistant's key is
#                        re-bound to the human's account, then pays with its saved card
#   rake check:isolation  adversarial cross-tenant + order-ownership isolation test
#   rake check:rls        opt-in Postgres RLS showcase — enforced-session three-way
#                        proof (script/rls_proof.rb) that a non-owner app_role is order-scoped
#   rake check:schema     self-discovery proof over the schema verb
#   rake check:redteam    adversarial regression battery (kiosk-redteam scenarios)
#   rake check:pow        commerce catalog-toll PoW demo (catalog 402 → solve → 200) at TOY
#                        params (n=96 k=5) unless KIOSK_POW_DIFFICULTY=high
#   rake check:slots_spec DB-free unit spec for the delivery-slot past-filter
#   rake check:cashier_spec DB-free unit spec for the order-ref uuid shape check
#   rake check:wire_args_spec DB-free unit spec for the whole WireArguments shape
#                        guard — the module that decides whether a hostile wire
#                        argument is a typed 400 or a booked order
#   rake check:conformance the four properties the protocol makes normative of
#                        this origin — routes resolve, a verb executes, a query
#                        answers its declared shape, data access is scoped to
#                        the principal — asserted with `bin/rails test`
#   rake check:race       pay-path regression: concurrency + typed 4xx
#                        + stuck-`paying` self-heal
#   rake demo:reconcile  resolve orders stuck in `paying` from local evidence

# ── Flow-driver runner — READ THE CHILD'S EXIT STATUS ─────────────────────────
#
# Every flow-driver invocation in this file goes through here, for the one line
# a bare capture does not have: `status.success?`.
#
# The tempting shape is a backtick capture feeding
# `JSON.parse(raw.lines.grep(/^\{/).last || raw)`, which never consults `$?`.
# A task's verdict then rests entirely on "did a line starting with `{`
# appear", and two failures fall out of that. It FAILS OPEN: a driver that
# prints its JSON line and THEN dies is reported as a PASS — and that is not
# hypothetical, kiosk-demo-getgrocery/script/rls_proof.rb prints its summary
# line before `exit 1` on a breach. And when a driver dies BEFORE printing one,
# the operator's headline is a JSON parse error naming the driver's FIRST line
# of output, which sends the reader to the wrong file instead of showing the
# driver's own message.
#
# So: status first, and on a non-zero child the abort quotes the child's own
# last output line. Only then is the JSON parsed. `Open3.capture2e` keeps the
# merged stdout+stderr interleaving and hands back the status the backticks
# throw away.
#
# NOT widened to the sibling `psql -X -tAc` probes in this file, deliberately:
# those capture with `2>&1` into a value that is then COMPARED, so a psql error
# lands in the string, fails its assertion and goes red. They fail closed.
def getgrocery_run_flow(flow_rb, env_str = "", env: {}, runner: "ruby")
  require "open3"
  require "shellwords"

  label       = File.basename(flow_rb)
  cmd         = "#{env_str} bundle exec #{runner} #{flow_rb.shellescape}".strip
  raw, status = Open3.capture2e(env, cmd)
  json_line   = raw.lines.grep(/^\{/).last

  puts raw.lines.reject { |l| l.start_with?("{") }.join
  puts json_line if json_line
  $stdout.flush # so the abort below lands AFTER the transcript, not before it

  unless status.success?
    last = raw.lines.map(&:chomp).reject { |l| l.strip.empty? || l.start_with?("{") }.last
    last ||= raw.lines.map(&:chomp).reject { |l| l.strip.empty? }.last # child printed only JSON
    how  = status.exitstatus ? "exit #{status.exitstatus}" : status.to_s
    abort "#{label} FAILED (#{how}): #{last || "(no output)"}"
  end

  begin
    JSON.parse(json_line || raw)
  rescue JSON::ParserError => e
    abort "#{label} did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
  end
end

# Start (or reuse) a local stripe-mock; return its HTTP base URL. The adversarial
# suites use it so the full pay→settlement→gate flow runs with NO real Stripe
# (fast, no key, no charges, CI-runnable). check:shop still uses real Stripe.
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
  desc "DROP and recreate the demo database, load the schema, seed it. Repeatable, and destructive every time: nothing already in that database survives."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    # db:schema:load unconditionally: db/structure.sql is TRACKED in every demo,
    # so a db:migrate arm would be unreachable in every checkout — and under
    # `schema_format = :sql` it would re-dump that tracked file, dirtying the
    # worktree. The canonical structure.sql is the source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc <<~DESC
    Reconcile orders stuck in `paying` — LOCAL evidence only.

    OPERATOR UTILITY, NOT A GATE. Every other task in this namespace
    asserts an invariant and exits non-zero when it breaks. This one reports:
    on a freshly seeded database it prints "nothing stuck" and exits 0 no
    matter what the code does, so it can never go red and CI does not run it.
    The logic below IS gated — by check:race's reconciliation block, which strands
    orders first and then sweeps them.

    A crash (or a failed status flip) between a successful capture and the
    paid-flip leaves an order `paying`: charged ONCE (the atomic claim makes a
    double charge impossible) but unpayable until reconciled. This sweep:

      • flips `paying` → `paid` for every stuck order that ALREADY has a
        settlement row — decisive local proof the charge was recorded;
      • LISTS the rest as UNRESOLVED with their cart-mandate ids, because only
        the payment processor knows whether money moved. It deliberately does
        NOT release those claims: releasing one is exactly the blind retry that
        could double-charge.

    This demo runs no background worker — invoke it manually (or from cron).
    Set MINUTES=n to change the "old enough to be stuck" cutoff (default 15).
  DESC
  task reconcile: :environment do
    minutes = Integer(ENV.fetch("MINUTES", "15"))
    result  = ValidatingPaymentProvider.reconcile_stuck_paying!(older_than_seconds: minutes * 60)

    puts "\n── Stuck-`paying` reconciliation (older than #{minutes} min) ──"
    if result[:healed].empty? && result[:unresolved].empty?
      puts "  nothing stuck. Exit 0."
      next
    end

    result[:healed].each { |id| puts "  HEALED      #{id} — settlement on file, status → paid" }
    result[:unresolved].each do |row|
      puts "  UNRESOLVED  #{row[:order_id]} — claimed #{row[:claimed_at]}, no settlement row."
      if row[:cart_mandate_ids].empty?
        # The engine persists the cart mandate (phase 1) BEFORE the claim, so a
        # wire-driven pay always leaves one. None here means this claim did not
        # come through /pay at all.
        puts "              No cart mandate references this order — it was not claimed via the /pay wire path."
      else
        puts "              Check the processor for a succeeded charge whose metadata.cart_mandate_id is " \
             "one of: #{row[:cart_mandate_ids].join(", ")}"
      end
    end
    puts "\n  healed=#{result[:healed].size} unresolved=#{result[:unresolved].size}"
    puts "  UNRESOLVED orders need a human/PSP check — they are NOT released automatically." unless result[:unresolved].empty?
  end
end

namespace :check do

  desc "DB-free unit spec for the delivery-slot past-filter + Dublin zone."
  task :slots_spec do
    spec = File.expand_path("../../spec/delivery_slots_spec.rb", __dir__)
    puts "\n── delivery_slots past-filter spec (no DB) ──"
    sh "ruby #{spec}"
  end

  desc "DB-free unit spec for the cashier's order-reference shape check."
  task :cashier_spec do
    spec = File.expand_path("../../spec/cashier_order_ref_spec.rb", __dir__)
    puts "\n── cashier order-ref shape spec (no DB) ──"
    sh "ruby #{spec}"
  end

  desc "DB-free unit spec for the WireArguments shape guards — every verb's first gate."
  task :wire_args_spec do
    spec = File.expand_path("../../spec/wire_arguments_spec.rb", __dir__)
    puts "\n── WireArguments shape-guard spec (no boot, no DB) ──"
    sh "ruby #{spec}"
  end

  # ── The conformance suite, and why it is `bin/rails test` ──────────────────
  #
  # THE FOUR PROPERTIES THE PROTOCOL MAKES NORMATIVE OF AN ORIGIN: its routes
  # resolve, a verb executes, a query answers the shape it declared, and data
  # access is scoped to the authenticated principal. An operator is asked to
  # conform to a document, so they have to be able to run its claims — the
  # assertions live in `kiosk-test-support` and `test/kiosk_conformance_test.rb`
  # is four assertion names around this demo's own fixtures.
  #
  # It is `bin/rails test` and not one file, so it also runs this shop's OWN
  # DB-backed regressions beside the conformance suite — a verb driven through
  # the same GUC-scoped session, asserting what it answers rather than which
  # shape it answers in. `test/create_order_inputs_test.rb` is the first:
  # `create_order` places an order and takes no existing one to amend, so an
  # `order_id` argument is refused by name rather than silently ignored — which
  # on this verb would be a second billable order answered `ok`.
  #
  # It is the ORDINARY Rails test runner on purpose. An adopting operator opens
  # a demo to find out what testing a Kiosk integration looks like, and what
  # they should find is the command they already type. This demo is the
  # Minitest worked example; kiosk-demo-hoteling is the RSpec one, off the same
  # gem and the same four checks.
  #
  # It runs in RAILS_ENV=test against its OWN database, so it neither reads nor
  # disturbs the seeded development data every other task in this file shares —
  # the fixtures are created per example and rolled back. Same recipe
  # kiosk-demo-prove's `check:test` uses.
  #
  # No server, no Postgres beyond that database, no PoW and no bearer: the
  # calls reach the registered handler through a GUC-scoped session. The WIRE
  # in front of those handlers is what check:shop, check:isolation and
  # check:redteam drive.
  desc "Conformance (routes resolve, verbs execute, queries answer their declared shape, data is principal-scoped) plus this shop's own DB-backed verb regressions — the whole of `bin/rails test`."
  task :conformance do
    puts "\n── Kiosk conformance (bin/rails test, RAILS_ENV=test) ──"
    sh "RAILS_ENV=test bundle exec rails db:drop db:create db:schema:load"
    sh "bundle exec rails test"
  end

  desc "Boot the server, run script/getgrocery_flow.rb end-to-end (no-human happy path: register→catalog→delivery_slots→create_order (delivery slot+address required)→payment_setup→pay (cart mirrors the order, EUR)→my_orders (paid)), assert."
  task :shop do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    # getgrocery uses the real Stripe adapter — no StubPsp. To run the
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

    port         = ENV.fetch("PORT", "3001")
    log          = "/tmp/kiosk-getgrocery-demo.log"
    db           = ENV.fetch("KIOSK_GETGROCERY_DB", "kiosk_getgrocery_development")
    flow_rb      = File.expand_path("../../script/getgrocery_flow.rb", __dir__)
    failures     = []

    # -- host resolution --
    # The domain here MUST be one config/environments/development.rb permits
    # (config.hosts) — that is the whole point of the lookup. A name that is not
    # listed breaks the ONE branch this block exists to offer: a developer who
    # follows the printed /etc/hosts line gets Rails 8 HostAuthorization 403s,
    # the 200-only readiness poll below burns its 40 seconds, and the run aborts
    # naming the wrong cause. CI never sees it — with no hosts entry the lookup
    # fails and everything dials 127.0.0.1.
    #
    # This name resolves PUBLICLY to the live demo box, so a bare lookup returns
    # a public IP, not an error. Only 127.0.0.1 is accepted, which is exactly
    # what an /etc/hosts entry produces: a local harness can never be steered
    # onto the deployed host by whatever DNS happens to answer.
    #
    # THE LOOKUP IS OPT-IN AND OFF BY DEFAULT. Unguarded, every local run of
    # every task in this file would send a DNS query for a `demo.kiosk.tech`
    # subdomain: an outbound query to the project's production domain, on each
    # invocation, for a value the run discards unless this machine has an
    # /etc/hosts entry. Set KIOSK_DEMO_HOST_LOOKUP=1 to ask for it. Without it
    # nothing here queries a resolver and the run dials 127.0.0.1 -- which is
    # what CI and a fresh checkout got out of the lookup anyway, so the default
    # costs nobody a branch they were reaching.
    #
    # AND THE RESCUE NAMES StandardError, BECAUSE `Resolv::ResolvError` COULD NOT
    # FIRE ON THE FAILURE THIS BLOCK EXISTS FOR. `Resolv::ResolvTimeout` is NOT a
    # `Resolv::ResolvError` -- measured on the shipped interpreter, its ancestors
    # are [Resolv::ResolvTimeout, Timeout::Error, RuntimeError, StandardError] --
    # so on a black-holed resolver, which is precisely the closed network this
    # fallback is written for, the narrower rescue let the exception out of the
    # rake task instead of falling back to 127.0.0.1. No resolver timeout is
    # configured anywhere here, so that stall is whatever the platform default is.
    host = begin
      addr = if ENV["KIOSK_DEMO_HOST_LOOKUP"] == "1"
        begin
          Resolv.getaddress("getgrocery.demo.kiosk.tech")
        rescue StandardError
          ""
        end
      else
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.demo.kiosk.tech"
      else
        puts "  (using 127.0.0.1 — to reach getgrocery.demo.kiosk.tech instead, add it to /etc/hosts as 127.0.0.1 and set KIOSK_DEMO_HOST_LOOKUP=1)"
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
      rescue StandardError
        nil
      end
      sleep 1
    end
    abort "Server did not become ready -- see #{log}" unless ready
    puts "  Server up at #{server_url}"

    # -- run script/getgrocery_flow.rb --
    puts "\n-- Running script/getgrocery_flow.rb --"
    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"
    result = getgrocery_run_flow(flow_rb, env_str)

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
    # ADDRESS-UPFRONT: an out-of-zone / district-less delivery address must be a
    # CLEAN 400 (bad_request), never a 500; the valid in-zone address must reach
    # 200 (asserted by http_slots/http_order above).
    check.call("http_slots_badzone", result["http_slots_badzone"], 400)
    check.call("slots_badzone_code", result["slots_badzone_code"], "bad_request")
    check.call("http_payment_setup", result["http_payment_setup"], 200)
    check.call("http_pay",           result["http_pay"],           200)
    check.call("http_my_orders",     result["http_my_orders"],     200)

    # order_id present
    oid = result["order_id"]
    if oid && !oid.to_s.empty?
      puts "  OK  order_id present (#{oid})"
    else
      failures << "order_id missing or empty"
      puts "  FAIL  order_id missing or empty"
    end

    # slot_at present — delivery is booked at order time
    sat = result["slot_at"]
    if sat && !sat.to_s.empty?
      puts "  OK  slot_at present (#{sat})"
    else
      failures << "slot_at missing or empty"
      puts "  FAIL  slot_at missing or empty"
    end

    # create_order's booked slot_at must EQUAL the date+start-time of the
    # delivery_slot the agent queried and chose — same day, NOT a fixed +1.
    chosen = result["chosen_slot_at"]
    if sat && chosen && sat == chosen
      puts "  OK  create_order slot_at == chosen delivery_slot slot_at (#{sat}) — no date drift"
    else
      failures << "slot-date agreement: create_order slot_at #{sat.inspect} != chosen delivery_slot slot_at #{chosen.inspect}"
      puts "  FAIL  slot-date agreement: create_order slot_at #{sat.inspect} != chosen delivery_slot slot_at #{chosen.inspect}"
    end

    # If the flow ran late enough that some of today's windows had already
    # started, delivery_slots hid them AND create_order rejected a past one with a
    # clean 400 bad_request (the negative control in script/getgrocery_flow.rb only fires
    # when a genuine past slot exists — a no-op before 08:00 Dublin or when booking
    # tomorrow, in which case this asserts nothing).
    psc = result["past_slot_check"]
    if psc.nil?
      puts "  OK  past-slot filter: no past slot to reject (booked tomorrow or before 08:00 Dublin) — filter is a no-op"
    elsif psc["http"] == 400 && psc["code"] == "bad_request"
      puts "  OK  past-slot filter: create_order on past slot id=#{psc["id"]} → 400 bad_request (un-bookable window rejected)"
    else
      failures << "past-slot filter: create_order on past slot expected 400 bad_request, got #{psc.inspect}"
      puts "  FAIL  past-slot filter: create_order on past slot got #{psc.inspect}"
    end

    # my_orders marks the settled order paid. The field is the TRI-state §11.6
    # requires (unpaid | pending | paid), not a boolean — `pending` is a capture
    # whose outcome is unknown and is NOT a settled order.
    if result["payment_state"] == "paid"
      puts "  OK  my_orders own order payment_state == paid"
    else
      failures << "my_orders payment_state expected \"paid\", got #{result["payment_state"].inspect}"
      puts "  FAIL  my_orders payment_state got #{result["payment_state"].inspect}"
    end

    # THE PAY BODY IS THE SETTLEMENT (0.4). `POST /kiosk/pay` keeps its path,
    # but its success body is the settlement object itself — there is no `ok`
    # flag left to read, and "did it settle?" is the 200 status plus a
    # settlement that names itself and its currency. The FIELDS are what is
    # asserted: a wrapper saying `true` would not prove the operator had booked
    # anything.
    pay = result["pay"] || {}
    %w[settlement_id psp_reference settled_amount_cents currency].each do |field|
      value = pay[field]
      if value.nil? || value.to_s.empty?
        failures << "pay body missing #{field} (got #{pay.inspect})"
        puts "  FAIL  pay body missing #{field}"
      else
        puts "  OK  pay.#{field} present (#{value})"
      end
    end
    if pay["currency"] == "eur"
      puts "  OK  the settlement is denominated in the operator's own currency (eur)"
    else
      failures << "settlement currency #{pay["currency"].inspect}, want \"eur\""
      puts "  FAIL  settlement currency #{pay["currency"].inspect} (want eur)"
    end

    # THE AMOUNT, on the REAL-STRIPE PATH ONLY. `settled_amount_cents` is the
    # PSP's `amount_received`, not something this app computes — which is what
    # makes it worth asserting, and also why it cannot be asserted against
    # stripe-mock: the mock's PaymentIntent fixture reports `amount_received: 0`
    # for every charge, so demanding the order's total here would fail on a
    # correct system for a reason that has nothing to do with getgrocery. The
    # mock path keeps the presence checks above; the cashier check
    # (ValidatingPaymentProvider) is what pins the amount BEFORE capture, and
    # check:redteam's TamperedPriceCart / InflatedTotalCart run it under the mock.
    if use_mock
      puts "  OK  (settled amount not asserted under stripe-mock — its fixture always reports amount_received=0)"
    elsif pay["settled_amount_cents"].to_i == result["total_cents"].to_i
      puts "  OK  Stripe settled the order's own total (#{pay["settled_amount_cents"]} eur)"
    else
      failures << "pay settled #{pay["settled_amount_cents"].inspect}, want the order's total #{result["total_cents"].inspect}"
      puts "  FAIL  pay settled #{pay["settled_amount_cents"].inspect} (want #{result["total_cents"].inspect})"
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

    # -- assertions: THIS RUN's rows, named by id --
    #
    # A DB-wide `COUNT(*) >= 1` passes on a row a PREVIOUS run left behind:
    # getgrocery's seeds create no orders, but `check:shop` is not always run
    # straight after `demo:setup`, so the beat could stop writing and all three
    # would stay green. The driver reports `order_id` and the `user_id` of the
    # agent it registered this run; both are anchors.
    this_order = result["order_id"]
    this_slot  = `psql -X -d #{db} -tAc "SELECT slot_at IS NOT NULL FROM orders WHERE id = '#{this_order}'" 2>&1`.strip
    if this_slot == "t"
      puts "  OK  this run's order has a delivery slot (id=#{this_order})"
    else
      failures << "orders[id=#{this_order}].slot_at expected set, got #{this_slot.inspect}"
      puts "  FAIL  orders[id=#{this_order}].slot_at — got #{this_slot.inspect}"
    end

    # Settlements carry no order_id, so the anchor is the principal: a fresh
    # agent registers every run, so EXACTLY ONE settlement must exist under it.
    this_user = result["user_id"]
    pm_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM kiosk.settlements WHERE user_id = '#{this_user}'" 2>&1`.strip
    if pm_count.to_i == 1
      puts "  OK  exactly one kiosk.settlements row for this run's principal (#{this_user})"
    else
      failures << "kiosk.settlements for user_id=#{this_user} expected 1, got #{pm_count.inspect}"
      puts "  FAIL  kiosk.settlements for this run's principal — got #{pm_count.inspect}"
    end

    items_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM order_items WHERE order_id = '#{this_order}'" 2>&1`.strip
    if items_count.to_i >= 1
      puts "  OK  this run's order has #{items_count} order_items (id=#{this_order})"
    else
      failures << "order_items for order #{this_order} expected >= 1, got #{items_count.inspect}"
      puts "  FAIL  order_items for this run's order — got #{items_count.inspect}"
    end

    # my_orders contains own order_id
    my_orders = result["my_orders"] || []
    if my_orders.any? { |o| o["order_id"] == result["order_id"] }
      puts "  OK  my_orders contains own order #{result["order_id"]}"
    else
      failures << "my_orders does not contain order_id #{result["order_id"].inspect}"
      puts "  FAIL  my_orders does not contain order_id #{result["order_id"].inspect}"
    end

    # -- the clock the order was QUOTED on is recorded ON THE ROW --
    #
    # `slot_at` is an instant and an instant cannot say which wall clock a human
    # was read it on; `orders.timezone` is that other half, written by the verb
    # that chose it from the delivery district. Every surface that renders the
    # window reads it from there rather than parsing the stored ADDRESS, so an
    # address that no longer resolves cannot quietly drop the render onto the
    # origin default.
    #
    # Two things at once, and the SECOND is the one that bites: the column is
    # written at all, and the `slot_label` the wire published NAMES exactly it.
    # An origin that recorded one clock and published another would be telling
    # its own back office and its caller two different times about one delivery.
    this_tz  = `psql -X -d #{db} -tAc "SELECT timezone FROM orders WHERE id = '#{this_order}'" 2>&1`.strip
    own_row  = my_orders.find { |o| o["order_id"] == this_order } || {}
    tz_label = own_row["slot_label"].to_s
    if !this_tz.empty? && tz_label.end_with?("(#{this_tz})")
      puts "  OK  the order records the clock it was quoted on (#{this_tz}) and my_orders names that one: #{tz_label}"
    else
      failures << "orders[id=#{this_order}].timezone=#{this_tz.inspect} vs my_orders slot_label=#{tz_label.inspect} — the recorded clock and the published one must be the same"
      puts "  FAIL  recorded clock #{this_tz.inspect} vs published slot_label #{tz_label.inspect}"
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

  # ── check:claim ───────────────────────────────────────────────────────────────
  desc <<~DESC
    Claim-rebind walkthrough — "why not MY account?".

    Boots the server against stripe-mock (the walkthrough charges a SEEDED
    card-on-file mapping — a mock fixture, no real key, no real charge; run
    check:shop for the real-Stripe path) and runs script/claim_flow.rb:

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

    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-getgrocery-claim.log"
    db   = ENV.fetch("KIOSK_GETGROCERY_DB", "kiosk_getgrocery_development")

    # The seeded account holder with the saved card, and her Devise credentials
    # (db/seeds.rb). The driver signs her in at /users/sign_in before she can
    # approve anything: there is no stub session channel to approve through.
    human_id       = "00000000-0000-0000-0000-000000000042"
    human_cus_id   = "cus_getgrocery_saved_card"
    human_email    = "hana@example.com"
    human_password = "getgrocery-demo-password"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = if ENV["KIOSK_DEMO_HOST_LOOKUP"] == "1"
        begin
          Resolv.getaddress("getgrocery.demo.kiosk.tech")
        rescue StandardError
          ""
        end
      else
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.demo.kiosk.tech"
      else
        puts "  (using 127.0.0.1 — to reach getgrocery.demo.kiosk.tech instead, add it to /etc/hosts as 127.0.0.1 and set KIOSK_DEMO_HOST_LOOKUP=1)"
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
      rescue StandardError
        nil
      end
      sleep 1
    end
    abort "Server did not become ready — see #{log}" unless ready
    puts "  Server up at #{server_url}"

    # ── run script/claim_flow.rb ──────────────────────────────────────────────
    flow_rb = File.expand_path("../../script/claim_flow.rb", __dir__)
    puts "\n── Running script/claim_flow.rb ──"
    env_str = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape} " \
              "HUMAN_USER_ID=#{human_id.shellescape} " \
              "HUMAN_EMAIL=#{human_email.shellescape} HUMAN_PASSWORD=#{human_password.shellescape}"
    result = getgrocery_run_flow(flow_rb, env_str)

    puts "\n══ Claim-rebind assertions ══"
    check = lambda do |label, ok|
      if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
    end
    check.call("standalone register → 201",                        result["http_register"] == 201)
    check.call("standalone payment_setup → setup_required (no card)", result["standalone_payment_setup"] == [200, "setup_required"])
    check.call("device_authorization carries the RFC 8628 fields",  result["da_fields"] == true)
    check.call("human signed in through the REAL /users/sign_in form", result["human_signed_in"] == true)
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
  # ── end check:claim ────────────────────────────────────────────────────────────

  # ── check:isolation ───────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial cross-tenant isolation test.

    Boots the server, runs script/isolation_flow.rb with two fresh principals (A and B),
    and asserts all cross-tenant denial properties including getgrocery's
    distinctive order-ownership mutation gates:

      HEADLINE: B cannot reschedule_delivery on A's PAID order (order-ownership gate)
      Assertion 1: B's my_orders excludes A's order (cross-tenant read blocked)
      Assertion 2: B's my_orders includes own order (positive control)
      Assertion 3: B's my_orders still excludes A's order after positive control
      Assertion 4: A's my_orders excludes B's order
      Assertion 5 (the principal is not an input): B's create_order with a
        forged user_id arg (A's UUID) → 400 bad_request naming user_id, refused
        by the published input_schema before the handler runs; and B's
        legitimate order has DB user_id == B, so ownership comes from the token.
      Assertion 6: a re-pay of an already-settled order → 403 WITH a body

    Off the wire, before any server starts: the owner scope with no Kiosk
    session open REFUSES (401 unauthenticated) rather than answering an empty
    relation — which is what a NULL identity predicate silently looks like,
    and it reads exactly like isolation working.

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: "demo:setup" do
    # ── OFF THE WIRE, BEFORE ANY SERVER STARTS ─────────────────────────────
    # Everything below proves B cannot read A's rows. This proves the scope all
    # of it rests on REFUSES when there is no principal at all, instead of
    # answering the empty relation a NULL identity predicate silently produces —
    # which reads exactly like isolation working, so every negative assertion
    # over it passes.
    #
    # The scope set is DERIVED from the loaded models, not named here, so a new
    # owner-scoped model is probed the day it is written and an app that has
    # lost them all fails as VACUOUS rather than passing on nothing. `:setup`
    # shells out and this task holds no Rails environment of its own, so the
    # probe runs in its own `rails runner` — which is exactly the caller it is
    # about.
    probe = <<~'RUBY'
      Rails.application.eager_load!
      scopes = ActiveRecord::Base.descendants.flat_map do |model|
        model.singleton_class.instance_methods(false)
             .grep(/_current_principal\z/).map { |name| [model, name] }
      end
      abort "VACUOUS — this app declares no *_current_principal scope at all" if scopes.empty?
      answered = scopes.reject do |model, name|
        begin
          model.public_send(name).count
          false
        rescue Kiosk::Server::Errors::Unauthenticated
          true
        end
      end
      unless answered.empty?
        abort "ANSWERED instead of refusing: " +
              answered.map { |m, n| "#{m}.#{n}" }.join(", ") +
              " — a silent empty relation is not isolation"
      end
      puts scopes.map { |m, n| "#{m}.#{n}" }.sort.join(", ") + " → all refused, 401 unauthenticated ✓"
    RUBY
    puts "\n── Off the wire: the identity-scoped scopes refuse with no session ──"
    abort "FAIL — an identity-scoped scope answered instead of refusing" \
      unless system("bundle", "exec", "rails", "runner", probe)

    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    # Adversarial suite → stripe-mock (no real charges, no key). The gates being
    # tested are pure Kiosk logic; Stripe is only the settlement rail, so a mock
    # exercises the full flow end-to-end.
    mock_url = start_stripe_mock
    puts "  (stripe-mock at #{mock_url} — adversarial suite, no real Stripe)"

    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-getgrocery-isolation.log"
    db   = ENV.fetch("KIOSK_GETGROCERY_DB", "kiosk_getgrocery_development")

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = if ENV["KIOSK_DEMO_HOST_LOOKUP"] == "1"
        begin
          Resolv.getaddress("getgrocery.demo.kiosk.tech")
        rescue StandardError
          ""
        end
      else
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.demo.kiosk.tech"
      else
        puts "  (using 127.0.0.1 — to reach getgrocery.demo.kiosk.tech instead, add it to /etc/hosts as 127.0.0.1 and set KIOSK_DEMO_HOST_LOOKUP=1)"
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
      rescue StandardError
        nil
      end
      sleep 1
    end
    abort "Server did not become ready — see #{log}" unless ready
    puts "  Server up at #{server_url}"

    # ── run script/isolation_flow.rb ──────────────────────────────────────────
    flow_rb = File.expand_path("../../script/isolation_flow.rb", __dir__)
    puts "\n── Running script/isolation_flow.rb (adversarial cross-tenant + order-ownership) ──"
    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"
    result = getgrocery_run_flow(flow_rb, env_str)

    user_id_b              = result["user_id_b"]
    order_id_a             = result["order_id_a"]
    order_id_b             = result["order_id_b"]
    forged_refusal         = result["forged_refusal"] || []
    owner_probe_order_id   = result["owner_probe_order_id"]
    b_reschedule_on_a_status = result["b_reschedule_on_a_status"]
    b_my_orders_before     = result["b_my_orders_before"] || []
    b_my_orders_after      = result["b_my_orders_after"]  || []
    a_my_orders_after      = result["a_my_orders_after"]  || []
    repay_settled_status   = result["repay_settled_status"]
    repay_body_len         = result["repay_body_len"].to_i
    repay_error_code       = result["repay_error_code"]

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    # HEADLINE: B cannot reschedule_delivery on A's PAID order (order-ownership gate)
    if b_reschedule_on_a_status == 403
      puts "  ✓  HEADLINE: B cannot reschedule_delivery on A's PAID order (order-ownership gate) → 403"
    else
      failures << "ISOLATION HOLE: B's reschedule_delivery on A's order returned #{b_reschedule_on_a_status} (expected 403)"
      puts "  ✗  HEADLINE: reschedule_delivery ownership gate FAILED — returned #{b_reschedule_on_a_status}"
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

    # Assertion 5a: the forged user_id is REFUSED by the published contract.
    # `create_order` declares `additionalProperties: false` and does not declare
    # `user_id` — the principal is not one of its inputs — so on the 0.4 wire the
    # schema layer answers a typed 400 NAMING the parameter before the handler
    # runs.
    forged_rc, forged_code, forged_detail = forged_refusal
    if forged_rc == 400 && forged_code == "bad_request" && forged_detail.to_s.include?("user_id")
      puts "  ✓  Assertion 5a: forged user_id → 400 bad_request naming user_id " \
           "(refused by input_schema before the handler runs)"
    else
      failures << "forged user_id not refused: #{forged_refusal.inspect}, want [400, \"bad_request\", …user_id…]"
      puts "  ✗  Assertion 5a FAILED: forged user_id → #{forged_refusal.inspect}"
    end

    # Assertion 5b: ownership comes from the TOKEN — the property the refusal
    # alone does not prove. B's LEGITIMATE order is B's in the database.
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM orders WHERE id = '#{owner_probe_order_id}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  ✓  Assertion 5b: DB orders.user_id == user_id_b (#{user_id_b}) — ownership is taken from the identity"
    else
      failures << "owner not taken from identity: DB orders.user_id is #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  ✗  Assertion 5b FAILED: unexpected user_id #{db_user_id.inspect} (expected B's)"
    end

    # Assertion 6: re-paying an ALREADY-SETTLED order is rejected WITH A BODY.
    # Every /pay error must carry an RFC 9457 problem document whose TOP-LEVEL
    # `code` an agent can branch on — never an empty/bodiless response. The case
    # it guards is a mistaken second /pay for an order already paid.
    if repay_settled_status == 403 && repay_body_len > 0 && repay_error_code == "forbidden"
      puts "  ✓  Assertion 6: re-pay of a settled order → 403 with a problem document (code=#{repay_error_code.inspect}, #{repay_body_len} bytes) — no empty pay error"
    else
      failures << "PAY-ERROR HOLE: re-pay of a settled order returned status=#{repay_settled_status.inspect} body_len=#{repay_body_len} code=#{repay_error_code.inspect} (expected 403, non-empty body, code=\"forbidden\")"
      puts "  ✗  Assertion 6 FAILED: re-pay error status=#{repay_settled_status.inspect} body_len=#{repay_body_len} code=#{repay_error_code.inspect}"
    end

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer isolation and order-ownership gates hold."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end check:isolation ────────────────────────────────────────────────────────

  # ── check:schema ──────────────────────────────────────────────────────────────
  desc <<~DESC
    Self-discovery proof — verifies the schema verb over HTTP.

    Boots the server and calls, with NO credential at all:
      GET /kiosk/schema

    Asserts:
      • `GET /kiosk/schema` answers 200 with NO Authorization header
      • the MODULE set lives in /.well-known/kiosk.json `capabilities` (`verbs` dropped)
      • capabilities is the MODULE set schema/queries/actions/pay and NOT events
      • schema.queries includes catalog, delivery_slots, my_orders (each with description)
      • schema.actions includes create_order, reschedule_delivery (each with description)
      • `create_order` declares NO `order_id` and closes its input object, so a sent
        one is a typed 400 rather than a silently ignored second billable order
      • schema.queries does NOT include stores, products_by_store, substitution_options
      • schema.actions does NOT include add_to_cart, apply_substitution, confirm_delivery
      • `payment_setup` and `kyc_status` publish BOTH a backing-off poll cadence and a GIVE UP horizon
      • the `<link rel="kiosk">` tag AND the `Link: <…>; rel="kiosk"` header both name
        a VERSIONED cut — not the mutable `skill.md` alias — and both agree with the
        `skill` pin in /.well-known/kiosk.json (protocol.md §4.5)

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: "demo:setup" do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-getgrocery-schema.log"

    host = begin
      addr = if ENV["KIOSK_DEMO_HOST_LOOKUP"] == "1"
        begin
          Resolv.getaddress("getgrocery.demo.kiosk.tech")
        rescue StandardError
          ""
        end
      else
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.demo.kiosk.tech"
      else
        puts "  (using 127.0.0.1 — to reach getgrocery.demo.kiosk.tech instead, add it to /etc/hosts as 127.0.0.1 and set KIOSK_DEMO_HOST_LOOKUP=1)"
        "127.0.0.1"
      end
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
      rescue StandardError
        nil
      end
      sleep 1
    end
    abort "Server did not become ready — see #{log}" unless ready
    puts "  Server up at #{server_url}"

    flow_rb = File.expand_path("../../script/schema_flow.rb", __dir__)
    puts "\n── Running script/schema_flow.rb ──"
    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"
    result = getgrocery_run_flow(flow_rb, env_str)

    puts "\n── Schema assertions ──"
    failures = []

    # ── THE DISCOVERY SIGNAL, READ OFF THE WIRE ──────────────────────────────
    #
    # protocol.md §4.5: an operator that advertises
    # `rel="kiosk"` MUST point it at a VERSIONED cut
    # (`https://kiosk.tech/skill-vMAJOR.MINOR.PATCH.md`), MUST NOT point it at
    # the mutable `skill.md` alias, and — where it also publishes a `skill` pin
    # — the tag, the header and the pin MUST all name the SAME url.
    #
    # ASSERTED HERE, OVER HTTP, AND NOT IN A UNIT TEST, because what §4.5
    # constrains is a SERVED BYTE: the tag is rendered by a view and the
    # header is set by a controller, so only a real response says what an
    # assistant scanning this page is actually handed. bin/check-version-parity
    # holds the SOURCE half (no literal url in app/, read the accessor); this
    # holds the wire half. The expected url is read from the origin's own
    # `/.well-known/kiosk.json`, never from a constant here — a second copy of
    # the pin is the thing both halves exist to prevent.
    require "net/http"
    require "uri"

    puts "\n── Discovery-signal assertions (protocol.md §4.5) ──"
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
        failures << "#{what} names the MUTABLE alias #{url} — §4.5 forbids it"
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

    # THE SCHEMA CALL WAS MADE WITHOUT A CREDENTIAL. The flow driver
    # sends no Authorization header, so this status IS the public-access proof.
    if result["schema_status"] == 200
      puts "  ✓  GET /kiosk/schema answered 200 with NO Authorization header"
    else
      failures << "unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}, want 200"
      puts "  ✗  unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}"
    end

    # THE MODULE SET, at its ONE home: `kiosk.json` `capabilities`. It is not
    # also published as `schema.verbs`, so there is no second copy of it that
    # could drift out of step with this one.
    %w[schema queries actions pay].each do |v|
      if capabilities.include?(v)
        puts "  ✓  capabilities includes #{v}"
      else
        failures << "capabilities missing #{v} (got #{capabilities.inspect})"
        puts "  ✗  capabilities missing #{v}"
      end
    end
    # ── THE EVENT MODULE, PRESENT — this origin declares 2 topics
    #
    # The trio below is the shape the fleet uses either way — module, url,
    # topic names. An origin that declares topics asserts all three present
    # and names them; one that declares none asserts the module absent, the
    # url unpublished, and the catalogue's events array present-but-EMPTY.
    # Asserting all three together is what catches either the capability or
    # the array drifting to the other's answer.
    if capabilities.include?("events")
      puts "  OK  capabilities includes events — this origin declares topics"
    else
      failures << "capabilities missing events (got #{capabilities.inspect}) — this origin declares topics"
      puts "  FAIL  capabilities missing events"
    end
    if result["discovery_events_url"].to_s.match?(%r{\Awss?://[^/]+/kiosk/events\z})
      puts "  OK  discovery publishes events_url on the wire's own origin and mount"
    else
      failures << "events_url missing or malformed (got #{result['discovery_events_url'].inspect})"
      puts "  FAIL  events_url missing or malformed"
    end
    declared_topics = %w[kyc_verification order_delivery order_payment payment_setup]
    if (result["schema_event_topics"] || []) == declared_topics
      puts "  OK  the catalogue names the topic(s) this demo declares"
    else
      failures << "catalogue topics #{(result['schema_event_topics'] || []).inspect} are not the declared #{declared_topics.inspect}"
      puts "  FAIL  catalogue topics are not the declared set"
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

    # The primary read query (catalog) and primary action
    # (create_order) advertise the machine-readable descriptor extensions.
    {
      queries => %w[catalog],
      actions => %w[create_order],
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

    # actions present with descriptions: create_order, reschedule_delivery
    %w[create_order reschedule_delivery].each do |aname|
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

    # The one verb that takes an `order_id` must DECLARE its uuid shape, not
    # merely describe it in prose. Since 0.4 the declaration is also ENFORCED:
    # `input_schema` is validated on every call, unconditionally, so the pattern
    # asserted below is what refuses a malformed order_id at the wire.
    # `Kiosk::UuidCheck` in the handler remains the floor for the values the pattern
    # admits — check:race pins that side, in-process. Asserted by BEHAVIOUR, not
    # by string equality: the published pattern must accept the ids create_order
    # hands out and reject the junk that would otherwise reach a `::uuid` cast.
    #
    # AND `create_order` MUST NOT DECLARE ONE. It places an order and takes no
    # existing one to amend; with `additionalProperties: false` in front of it,
    # an `order_id` sent anyway is a typed 400 naming the argument rather than a
    # silent second billable order.
    require "securerandom"
    %w[reschedule_delivery].each do |aname|
      prop = (actions.find { |a| a["name"] == aname } || {})
             .dig("input_schema", "properties", "order_id") || {}
      pattern = prop["pattern"]
      if pattern.nil?
        failures << "#{aname}.order_id declares no uuid pattern"
        puts "  ✗  #{aname}.order_id declares no uuid pattern"
        next
      end

      rx = Regexp.new(pattern)
      accepts = Array.new(20) { SecureRandom.uuid }.all? { |u| rx.match?(u) }
      rejects = ["not-a-uuid", "12345", "'; DROP TABLE orders; --", SecureRandom.uuid.delete("-")]
                .none? { |bad| rx.match?(bad) }
      if accepts && rejects
        puts "  ✓  #{aname}.order_id declares a uuid pattern that accepts real ids and rejects junk"
      else
        failures << "#{aname}.order_id pattern #{pattern.inspect} accepts=#{accepts} rejects_junk=#{rejects}"
        puts "  ✗  #{aname}.order_id pattern #{pattern.inspect} does not behave as a uuid check"
      end

      if prop["format"] == "uuid"
        puts "  ✓  #{aname}.order_id also declares format: uuid"
      else
        failures << "#{aname}.order_id missing format: uuid (got #{prop["format"].inspect})"
        puts "  ✗  #{aname}.order_id missing format: uuid"
      end
    end

    create_inputs = (actions.find { |a| a["name"] == "create_order" } || {})["input_schema"] || {}
    if (create_inputs["properties"] || {}).key?("order_id")
      failures << "create_order declares an order_id — it takes no existing order to amend"
      puts "  ✗  create_order declares an order_id"
    elsif create_inputs["additionalProperties"] != false
      failures << "create_order's input_schema is not closed — a sent order_id would be ignored, not refused"
      puts "  ✗  create_order's input_schema is not closed"
    else
      puts "  ✓  create_order declares no order_id and closes its object — a sent one is a typed 400"
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

    # ── THE POLL BUDGET IS A PUBLISHED CONTRACT, SO IT IS ASSERTED ────────────
    # The out-of-band verbs below are learned about by RE-POLLING and nothing
    # else — the wire has no server→assistant push — so their descriptors carry
    # a cadence and a give-up horizon, QUOTING kiosk.tech/skill.md's tiered
    # schedule rather than a rival flat one. NOTHING ELSE THAT RUNS READS EITHER
    # VALUE BACK — they live only in the source they are written into — so
    # without this beat an edit could drop the horizon and every gate would stay
    # green. It is asserted on the SERVED descriptor, because that is the
    # document an assistant reads.
    #
    # STRUCTURE, NOT THE MINUTES. Both tiers must be present, the second must be
    # SLOWER than the first (a tiering that is not one is not a schedule), and a
    # horizon must be named in minutes. The exact numbers are deliberately NOT
    # pinned: writing "5" and "15" here would make this file a third place the
    # schedule lives, and a derived copy of a schedule is one copy too many.
    poll_tiers   = /re-check every ~(\d+) seconds for the first minute, then every ~(\d+) seconds/
    poll_horizon = /GIVE UP after about (\d+) minutes?/
    { actions => ["payment_setup"], queries => ["kyc_status"] }.each do |list, names|
      names.each do |vname|
        entry = list.find { |e| e["name"] == vname }
        if entry.nil?
          failures << "schema is missing #{vname} — the poll-budget assertion cannot run"
          puts "  FAIL  schema is missing #{vname}"
          next
        end
        desc = entry["description"].to_s
        tiers   = desc.match(poll_tiers)
        horizon = desc.match(poll_horizon)
        if tiers.nil?
          failures << "#{vname} description publishes no poll cadence: #{desc.inspect}"
          puts "  FAIL  #{vname} publishes no poll cadence"
        elsif tiers[2].to_i <= tiers[1].to_i
          failures << "#{vname} cadence does not back off: ~#{tiers[1]}s then ~#{tiers[2]}s"
          puts "  FAIL  #{vname} cadence does not back off (~#{tiers[1]}s then ~#{tiers[2]}s)"
        else
          puts "  OK    #{vname} publishes a backing-off cadence (~#{tiers[1]}s, then ~#{tiers[2]}s)"
        end
        if horizon.nil? || horizon[1].to_i <= 0
          failures << "#{vname} description publishes no GIVE UP horizon: #{desc.inspect}"
          puts "  FAIL  #{vname} publishes no GIVE UP horizon"
        else
          puts "  OK    #{vname} publishes a give-up horizon (~#{horizon[1]} minutes)"
        end
      end
    end

    # ── §8.3 — THE PUBLISHED EXAMPLES, AGAINST THEIR OWN SCHEMAS ─────────────
    #
    # Matrix SPEC-084, on the bytes script/schema_flow.rb GOT off
    # `/kiosk/schema` a moment ago — an `example_params` its own `input_schema`
    # refuses, or an `example_row` its own `output_schema` rejects, is a
    # published lie in the document an assistant reads first. The loop, and the
    # `limit`/`cursor` exemption the engine applies to a real request, live in
    # script/descriptor_examples.rb — ONE file across the seven origins. The
    # only per-demo part is the floor: how many examples THIS origin publishes,
    # so a refactor that stopped publishing them fails here instead of turning
    # the loop into a silent no-op.
    require_relative "../../script/descriptor_examples"

    puts "\n── §8.3 descriptor examples vs their own schemas (SPEC-084) ──"
    failures.concat(
      descriptor_example_failures(queries: queries, actions: actions, minimum: 8),
    )

    if failures.empty?
      puts "\n  All schema assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end check:schema ───────────────────────────────────────────────────────────

  # ── check:redteam ─────────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery — kiosk-redteam.

    Boots getgrocery, runs all generic Kiosk::Redteam scenarios and asserts
    each applicable attack is BLOCKED:

      BLOCKED  CrossTenantRead        — B's my_orders must not include A's orders
      BLOCKED  ForgedUserId           — a forged user_id in create_order is REFUSED
                                        (400 bad_request: the principal is not a
                                        declared input), and B's own order stays B's
      BLOCKED  UnpaidGatedAction      — reschedule_delivery without a settled mandate rejected
      BLOCKED  SpentResourceReuse     — a paid order reschedules once; the second attempt rejected
      BLOCKED  PayForOtherUseSelf     — mandate paid for one order cannot gate another
      BLOCKED  MandatePrincipalSwap   — B signs a mandate with A's identity; rejected
      BLOCKED  MandateReplay          — B re-submits A's signed mandate JWS; rejected
      BLOCKED  TokenTampering         — altered JWT (claim flipped) rejected 401
      BLOCKED  PrivilegeSelfSelection — agent cannot self-assign elevated privilege
      BLOCKED  DeviceGrantRoleSelfSelection — the binding ceremony's unauthenticated
                                        opening request refuses `role`/`scope`, at a
                                        DECLARED value as well as an invented one
      BLOCKED  WrongCurrencyCart      — usd cart at a EUR operator rejected at capture
      BLOCKED  TamperedPriceCart      — line price differing from the catalog rejected
      BLOCKED  InflatedTotalCart      — total above the sum of the lines rejected
      BLOCKED  MalformedItemsCart     — a non-array (or non-object-element) `items` is a
                                        typed 400, never a 500
      BLOCKED  HostileArgShapes       — boolean/array/object/junk on delivery_slot_id,
                                        delivery_date, delivery_address and order_id →
                                        typed 400, never a 500
      BLOCKED  UnregisteredVerbIsOrdinaryRefusal — POST /kiosk/query and POST /kiosk/run
                                        name no registered verb and no route draws them, so
                                        both answer the ordinary 404 any undrawn path gets,
                                        bearer or not (a routing miss precedes the
                                        credential); no privileged endpoint hides behind a
                                        generic-sounding word
      BLOCKED  MethodMismatch         — a GET at an action's path draws no route, so it is
                                        the same plain 404 with no Allow, and the write
                                        never runs
      BLOCKED  PastDeliveryDate       — a delivery date in the past is a named 400,
                                        never an ambiguous 200 []
      BLOCKED  CallerZoneIsNotInferred — with no Kiosk-Timezone the answer is the same
                                        whatever locale, geolocation hint or proxy IP
                                        the request also carries, on an origin that
                                        demonstrably reads the header when it is sent
      BLOCKED  OneRenderingPerRow     — two callers on clocks 25 hours apart get
                                        byte-identical windows, and neither answer
                                        names the caller's own zone
      BLOCKED  MachineTimestampsIgnoreTheCallerClock — an auth challenge's exp is an
                                        instant, not a service time: it does not move
                                        with the caller's declared clock
      BLOCKED  KycBrokerUnwired       — with no KYC broker configured (which is how THIS
                                        task boots the origin, and how a plain `rails s`
                                        does), request_kyc answers 501 module_not_served
                                        with a hint saying retrying will not help —
                                        never a 500 carrying a Ruby exception message
      BLOCKED  RegistrationWithoutPow — register without a valid PoW proof rejected

    Scenarios that require a surface getgrocery does not expose SKIP cleanly:
      SKIPPED  MissingKyc, ExpiredKyc, ForgedKyc  (requires_kyc: false)

    Note: RegistrationWithoutPow IS run — getgrocery gates registration with
    PoW (registration_pow_count = 1), so a missing/bad register proof is
    rejected.

    Exits 0 when all applicable scenarios are BLOCKED; exits 1 on any BREACH.
    A BREACH = a real hole in getgrocery — fix the app, not the scenario.
  DESC
  task redteam: "demo:setup" do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    # getgrocery uses the real Stripe adapter (no StubPsp).
    # Adversarial battery → stripe-mock (no real charges, no key). The gates
    # under test are pure Kiosk logic; Stripe is only the settlement rail.
    mock_url = start_stripe_mock
    puts "  (stripe-mock at #{mock_url} — adversarial battery, no real Stripe)"

    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-getgrocery-redteam.log"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = if ENV["KIOSK_DEMO_HOST_LOOKUP"] == "1"
        begin
          Resolv.getaddress("getgrocery.demo.kiosk.tech")
        rescue StandardError
          ""
        end
      else
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.demo.kiosk.tech"
      else
        puts "  (using 127.0.0.1 — to reach getgrocery.demo.kiosk.tech instead, add it to /etc/hosts as 127.0.0.1 and set KIOSK_DEMO_HOST_LOOKUP=1)"
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
      rescue StandardError
        nil
      end
      sleep 1
    end
    abort "Server did not become ready — see #{log}" unless ready
    puts "  Server up at #{server_url}"

    # ── run script/redteam_suite.rb ───────────────────────────────────────────
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
  # ── end check:redteam ──────────────────────────────────────────────────────────

  desc <<~DESC
    Pay-path regression: concurrency, typed 4xx, reconciliation.

    Resets the DB, then runs script/race_flow.rb IN-PROCESS (real Postgres, real
    threads on pooled connections, a controllable PSP stub) to prove:

      (a) NO SWAP      — an in-flight /pay for order O cannot have O's items
                         rewritten under it ("pay €1, get €500" is out):
                         create_order names no existing order, so a concurrent
                         expensive cart lands on its OWN row and O is untouched.
      (b) AT-MOST-ONCE — under N racing /pay for one order, exactly ONE
                         captures; the rest are cleanly rejected.
      (c) TYPED 4xx    — a malformed order_id is a 400 bad_request at both of
                         the sites that cast one to `::uuid` (the cart and
                         reschedule_delivery), never a raw 500, and nothing
                         reaches the PSP.
      (d) RECONCILED   — an order stranded in `paying` heals to `paid` from its
                         settlement row, while one whose outcome only the PSP
                         knows is reported UNRESOLVED and keeps its claim.

    Exits 0 iff every invariant holds; non-zero on any breach.
  DESC
  task race: "demo:setup" do
    require "shellwords"
    driver = File.expand_path("../../script/race_flow.rb", __dir__)
    puts "\n── Running script/race_flow.rb (pay path) ──"
    # A generous pool so N racing threads each get their own real connection.
    ok = system({ "RAILS_MAX_THREADS" => "12" }, "bundle exec rails runner #{driver.shellescape}")
    exit(ok ? 0 : 1)
  end

end


namespace :check do
  desc <<~DESC
    Commerce catalog-toll PoW demo (KIOSK_POW_DEMO=1).

    Boots the server with the catalog gate active and runs script/pow_flow.rb:
    catalog query → 402 equihash → solve.py → 200; wrong nonce → 403 + penalty.

    RUNS AT TOY PARAMETERS BY DEFAULT — Equihash n=96 k=5, `KIOSK_POW_DIFFICULTY`'s
    `low`. That is a sub-second solve, which is what keeps this task runnable in
    CI and on a laptop, and it is NOT the toll a real operator charges.

    To exercise the SHIPPED parameters — n=168 k=7, kiosk-pow-equihash's own
    default:

      KIOSK_POW_DIFFICULTY=high bundle exec rake check:pow

    Budget ~10 s and ~1.3 GiB of RSS PER PROOF from the reference solver
    (bench/README.md, measured on one M-series laptop core) — that gibibyte is
    that solver's sorted-nonce table, not a floor these params impose on every
    solver. The flow pays that toll MORE THAN ONCE: registration is tolled too,
    and script/equihash_register.rb solves it transparently for each identity
    the flow mints. So the run COUNTS every solve and prints the total beside
    its verdict instead of promising a number typed here. The task
    prints the (n, k) it actually ran at and ASSERTS it against the challenge
    the server issued, so a recording can never leave a viewer guessing which
    toll they watched being paid.

    Requires python3 + numpy.
  DESC
  task :pow do
    require "resolv"
    require "net/http"; require "uri"; require "json"; require "shellwords"

    abort "numpy not found (pip install numpy)" unless system("python3 -c 'import numpy' 2>/dev/null")

    # ── The toll this run pays, DERIVED and then PRINTED ──────────────────────
    #
    # `check:pow` is the only end-to-end exercise of the proof-of-work plane in
    # this repo, and it runs at `Kiosk::Pow::Equihash::Difficulty`'s `low` default while the
    # shipped kiosk-pow-equihash default is n=168 k=7, so a reader watching
    # this task must be told which of the two they are seeing. The ambient
    # `KIOSK_POW_DIFFICULTY` is FORWARDED to the server this task spawns, and
    # the pair is read off {Kiosk::Pow::Equihash::Difficulty} — the same module the initializer
    # reads — rather than typed here.
    pow_level  = Kiosk::Pow::Equihash::Difficulty.level
    pow_params = Kiosk::Pow::Equihash::Difficulty.params

    # The catalog-toll flow never pays; default a dummy Stripe test key so the
    # initializer boots (setup + server) without a real key or stripe-mock.
    ENV["STRIPE_SECRET_KEY"] = "sk_test_dummy" if ENV["STRIPE_SECRET_KEY"].to_s.empty?
    Rake::Task["demo:setup"].invoke

    port         = ENV.fetch("PORT", "3001")

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = if ENV["KIOSK_DEMO_HOST_LOOKUP"] == "1"
        begin
          Resolv.getaddress("getgrocery.demo.kiosk.tech")
        rescue StandardError
          ""
        end
      else
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.demo.kiosk.tech"
      else
        puts "  (using 127.0.0.1 — to reach getgrocery.demo.kiosk.tech instead, add it to /etc/hosts as 127.0.0.1 and set KIOSK_DEMO_HOST_LOOKUP=1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    log          = "/tmp/kiosk-getgrocery-pow.log"
    flow_rb      = File.expand_path("../../script/pow_flow.rb", __dir__)
    failures     = []

    # `fetch`, not a default: ENV["STRIPE_SECRET_KEY"] is filled in above,
    # before demo:setup runs, so there is nothing left here to fall back to.
    stripe_key = ENV.fetch("STRIPE_SECRET_KEY")

    # ONE owner for the toy counter's location. The server and the driver are
    # two processes that never meet; this task spawns both, so it is the only
    # place the path can be stated once. Wiped HERE — the beat asserts exact
    # counts, and the initializer must not truncate a store at boot in a file
    # an adopter copies.
    bad_proof_db = File.expand_path("../../tmp/bad-proof.sqlite3", __dir__)
    require "fileutils"
    FileUtils.mkdir_p(File.dirname(bad_proof_db))
    FileUtils.rm_f(bad_proof_db)

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => server_url, "KIOSK_POW_DEMO" => "1",
        "KIOSK_TEST_AUTOCARD" => "1", "STRIPE_SECRET_KEY" => stripe_key,
        "KIOSK_BAD_PROOF_DB" => bad_proof_db,
        # Forwarded, not defaulted: naming it here is what makes the server's
        # level and the level this task prints the SAME read.
        "KIOSK_POW_DIFFICULTY" => pow_level },
      "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
      out: log, err: log,
    )
    begin
      ready = false
      40.times do
        begin
          ready = true if Net::HTTP.get_response(URI("#{server_url}/.well-known/kiosk.json")).code.to_i == 200
        rescue StandardError
          nil
        end
        break if ready
        sleep 1
      end
      abort "Server did not become ready — see #{log}" unless ready
      puts "  Server up at #{server_url} (catalog PoW active)"
      puts "  toll: Equihash n=#{pow_params[:n]} k=#{pow_params[:k]} " \
           "(KIOSK_POW_DIFFICULTY=#{pow_level}#{pow_level == Kiosk::Pow::Equihash::Difficulty::DEFAULT ? ", the default" : ""})"
      if Kiosk::Pow::Equihash::Difficulty.high?
        puts "  These are the SHIPPED parameters — the toll a real operator charges. " \
             "Expect ~10 s and ~1.3 GiB per proof from the reference solver — that " \
             "GiB is its table, not a floor these params impose on every solver. " \
             "The flow solves MORE than one proof — registration is tolled too — " \
             "and the count it actually paid is printed beside the verdict."
      else
        puts "  TOY parameters. The shipped kiosk-pow-equihash default is n=168 k=7 — " \
             "re-run with KIOSK_POW_DIFFICULTY=high to pay the real toll."
      end

      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{server_url.shellescape} " \
            "KIOSK_BAD_PROOF_DB=#{bad_proof_db.shellescape}"
      result = getgrocery_run_flow(flow_rb, env)

      puts "\n══ Catalog PoW assertions (Equihash n=#{pow_params[:n]} k=#{pow_params[:k]}, " \
           "KIOSK_POW_DIFFICULTY=#{pow_level}) ══"
      check = lambda do |label, ok|
        if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
      end
      # WHICH TOLL WAS ACTUALLY PAID, asserted off the WIRE rather than
      # printed off this task's own read. A banner naming the parameters is a
      # claim; the challenge the server issued is evidence, and it follows an
      # operator override or a policy this task cannot see. Without it the
      # opt-in path could silently keep running at `low` while the recording
      # said `high`.
      served_params = result["challenge_params"].is_a?(Hash) ? result["challenge_params"] : {}
      check.call("toll served at n=#{pow_params[:n]} k=#{pow_params[:k]} (the wire's own params, " \
                 "not this task's read); got n=#{served_params["n"].inspect} k=#{served_params["k"].inspect}",
                 served_params["n"].to_i == pow_params[:n] && served_params["k"].to_i == pow_params[:k])
      # HOW MANY PROOFS THIS RUN ACTUALLY PAID FOR, counted by the driver where
      # the solver runs rather than typed here. The total covers BOTH the tolled
      # catalog query's challenges and the registration proof `equihash_register`
      # solves transparently for each identity the flow mints — counting the
      # query's alone reports the wrong number.
      # It is the number a viewer multiplies by the per-proof budget to size a
      # recording, so it is ASSERTED — a printed total that does not equal its own
      # two parts is a counter that has come loose from what it counts.
      solved     = result["proofs_solved"].to_i
      reg_proofs = result["registration_proofs_solved"].to_i
      qry_proofs = result["tolled_query_proofs"].to_i
      check.call("proofs solved this run: #{solved} (#{reg_proofs} at registration, " \
                 "#{qry_proofs} at the tolled catalog query) — multiply by the per-proof budget",
                 solved.positive? && solved == reg_proofs + qry_proofs)
      check.call("catalog challenged (402)",         result["http_challenge"] == 402)
      check.call("served after solve (200 + rows)",  result["served"] == true && result["catalog_rows"].to_i >= 1)
      check.call("wrong nonce rejected (403)",       result["http_wrong_nonce"] == 403)
      check.call("on_bad_proof penalized",           result["bad_proof_count"].to_i >= 1)
      # PER-IDENTITY: the flow's second, innocent identity must be
      # untouched by the first identity's wrong nonce.
      check.call("per-identity counter: innocent identity stays 0",
                 result.key?("other_bad_proof_count") && result["other_bad_proof_count"].to_i.zero?)
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All catalog PoW assertions PASSED at Equihash n=#{pow_params[:n]} " \
           "k=#{pow_params[:k]} (KIOSK_POW_DIFFICULTY=#{pow_level})."
      unless Kiosk::Pow::Equihash::Difficulty.high?
        puts "  These are TOY parameters. `KIOSK_POW_DIFFICULTY=high bundle exec rake check:pow` " \
             "runs the same flow at the shipped n=168 k=7."
      end
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end

  # ── check:rls — additive RLS-enforce reference (the suite's RLS showcase) ────
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

    Three-way proof (script/rls_proof.rb):
      1. Negative control: owner/superuser WITHOUT SessionContext sees BOTH rows
         (superuser bypasses RLS — the pre-fix no-op / leak).
      2. Enforced session for A: raw unscoped SELECT * FROM orders → only A's row.
      3. Enforced session for B: raw unscoped SELECT * FROM orders → only B's row.

    Exits 0 if all three assertions pass; exits 1 on any failure. The default
    shop path is completely unaffected: structure.sql unchanged, no migration added.
  DESC
  task :rls do
    # getgrocery's initializer requires a Stripe key to boot; the RLS proof
    # never pays, so default a dummy test key (same as check:pow).
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
    overlay_rb = File.expand_path("../../script/rls_overlay.rb", __dir__)
    puts "\n── Applying RLS overlay ──"
    sh "bundle exec rails runner #{overlay_rb}"

    # ── Step 5: Run the three-way isolation proof (KIOSK_RLS_ENFORCE=1) ─────
    proof_rb = File.expand_path("../../script/rls_proof.rb", __dir__)
    puts "\n── Running RLS isolation proof (KIOSK_RLS_ENFORCE=1) ──"
    require "json"
    result = getgrocery_run_flow(proof_rb, "KIOSK_RLS_ENFORCE=1", runner: "rails runner")

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
  # ── end check:rls ──────────────────────────────────────────────────────────
end


namespace :check do
  # ── check:agecheck ──────────────────────────────────────────────────────────
  #
  # THIS `desc` DOES NOT NAME THE SECOND DATABASE, ON PURPOSE. The task
  # drops a SIBLING demo's database through script/prove_broker_boot.rb; the
  # disclosure surfaces for that are this demo README's generated PREREQS block
  # and the banner the helper prints immediately before the drop. `rake -T`
  # renders only a description's FIRST SENTENCE, so putting the warning here
  # would replace what the task IS in `rake -T` rather than add to it —
  # measured, and written up in bin/check-demo-prereqs.
  desc <<~DESC
    Alcohol age-gate (18+ anonymized KYC) — the LOW-liability age-gated-purchase
    showcase for anonymized KYC (KYC-DEMO-SCOPE (b): the gate lives on the
    PURCHASE where the transaction closes, not on a high-liability rental).

    A TWO-SERVER integration: boots the KYC broker (kiosk-demo-prove) on its
    own port — getgrocery is a SECOND registered operator alongside skooti — then
    boots getgrocery and drives script/agecheck_flow.rb across both apps:

      A1  create_order WITH the alcohol item, no KYC → 403 kyc_required — an RFC
          9457 problem document whose top-level `code` carries that name and
          whose `hint` points the agent at `request_kyc`.
      A2  run request_kyc → 200 with a broker verification_url; human approves the
          broker page; the broker POSTs its signed {age_over_18} claim to
          /kyc/callback; poll kyc_status → approved returns the broker jws.
      A3  submit the jws to /agents/kyc → 200 (attribute age_over_18 recorded).
      A4  retry create_order WITH the alcohol item → 200; payment_setup + pay
          (cart mirrors the order at catalog EUR prices) → settle.
      B   NON-alcohol order with NO KYC at all → 200 directly (positive control —
          the age-gate fires ONLY on age_restricted items).
      R1  a FORGED age attestation (wrong signing key) → 403 at /agents/kyc.
      R2  alcohol create_order after the forged submit → still 403 (blocked).

    Reframe honesty (KYC-DEMO-SCOPE (a)): this age-gate is the PROPER home of
    anonymized KYC — a low-liability eligibility check where the transaction
    closes. It does NOT confer accountability, which is why anonymized KYC is
    NOT used for high-liability actions.

    Exits 0 when all hold; exits 1 on any miss. A red assertion = the age-gate is
    broken (or leaked onto the non-alcohol path) — fix the app, not the test.

    DEPLOY FOLLOW-UP: getgrocery is allow-listed at the broker only by this test
    harness; a standing deploy allow-list entry for getgrocery is a follow-up.
  DESC
  task agecheck: "demo:setup" do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"
    require "shellwords"
    require_relative "../../script/prove_broker_boot"

    # The full flow pays for the alcohol order → needs the Stripe adapter to
    # settle. Run against stripe-mock (no key, no real charge) with autocard.
    mock_url = start_stripe_mock
    puts "  (stripe-mock at #{mock_url} — age-gate flow, no real Stripe)"

    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-getgrocery-agecheck.log"

    host = begin
      addr = if ENV["KIOSK_DEMO_HOST_LOOKUP"] == "1"
        begin
          Resolv.getaddress("getgrocery.demo.kiosk.tech")
        rescue StandardError
          ""
        end
      else
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.demo.kiosk.tech"
      else
        puts "  (using 127.0.0.1 — to reach getgrocery.demo.kiosk.tech instead, add it to /etc/hosts as 127.0.0.1 and set KIOSK_DEMO_HOST_LOOKUP=1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    # TWO-SERVER GATE: boot the KYC broker first (with getgrocery's callback
    # host allow-listed + its shared secret), wire getgrocery's trust + intake
    # config at it, then boot getgrocery and drive the cross-app age-gate flow.
    result = nil
    ProveBrokerBoot.with_broker(operator_host: host) do |broker|
      puts "\n── Starting getgrocery (age-gate proof) on #{server_url} ──"

      File.truncate(log, 0) if File.exist?(log)
      boot_env = {
        "KIOSK_ISSUER"        => kiosk_issuer,
        "KIOSK_TEST_AUTOCARD" => "1",
        "STRIPE_MOCK_URL"     => mock_url,
        "STRIPE_SECRET_KEY"   => "sk_test_mock",
      }.merge(broker[:wiring])
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

      ready = false
      40.times do
        begin
          res = Net::HTTP.get_response(URI("#{server_url}/.well-known/kiosk.json"))
          if res.code.to_i == 200
            ready = true
            break
          end
        rescue StandardError
          nil
        end
        sleep 1
      end
      abort "Server did not become ready — see #{log}" unless ready
      puts "  Server up at #{server_url}"

      flow_rb = File.expand_path("../../script/agecheck_flow.rb", __dir__)
      puts "\n── Running script/agecheck_flow.rb (getgrocery + KYC broker) ──"
      driver_env = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} " \
                   "KIOSK_PROVE_BROKER_URL=#{broker[:broker_url]} " \
                   "KIOSK_PROVE_ISSUER=#{broker[:wiring]["KIOSK_PROVE_ISSUER"]}"
      driver_env_h = { "KIOSK_PROVE_TEST_SIGNING_KEY_PEM" =>
                         broker[:wiring]["KIOSK_PROVE_TEST_SIGNING_KEY_PEM"] }
      result = getgrocery_run_flow(flow_rb, driver_env, env: driver_env_h)
    end

    puts "\n── Age-gate assertions ──"
    puts "  (KYC-DEMO-SCOPE (a): this age-gate is the PROPER home of anonymized KYC —"
    puts "   a low-liability eligibility check where the transaction closes; it does NOT"
    puts "   confer accountability, which is why anonymized KYC is not used for"
    puts "   high-liability actions.)\n\n"
    failures = []
    check = lambda do |label, ok|
      if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
    end

    check.call("A1 alcohol create_order without KYC → 403 kyc_required",
               result["http_alcohol_no_kyc"] == 403 && result["alcohol_no_kyc_code"] == "kyc_required")
    check.call("A1 403 hint points to request_kyc",
               result["alcohol_no_kyc_hint_to_req"] == true)
    check.call("A2 request_kyc → 200 with a broker verification_url",
               result["http_request_kyc"] == 200 && result["request_kyc_verification_url"].to_s.include?("/verify?request="))
    # A2b: the OUTSTANDING-INTAKE CAP. Without it one registration proof buys
    # unlimited broker intakes — free against a stub, a budget hole behind a
    # paid issuer. The FOURTH pending request for one account is refused with
    # the wire's own `quota_exceeded` (429), BEFORE the broker is called.
    check.call("A2b a fourth PENDING request_kyc → 429 quota_exceeded (per-principal cap)",
               result["http_request_kyc_capped"] == 429 && result["request_kyc_capped_code"] == "quota_exceeded")
    check.call("A2 human approved broker page → callback landed, kyc_status approved, jws relayed",
               result["http_approve_page"] == 200 && result["kyc_status"] == "approved" && result["kyc_jws_relayed"] == true)
    check.call("A3 relayed kyc_jws accepted at /agents/kyc with {age_over_18}",
               result["http_kyc_submit"] == 200 && (result["kyc_attributes"] || {})["age_over_18"] == true)
    check.call("A4 retry alcohol create_order WITH KYC → 200",
               result["http_alcohol_with_kyc"] == 200 && !result["alcohol_order_id"].to_s.empty?)
    check.call("A4 payment_setup → 200 and pay the alcohol order → 200 (pi_ settlement)",
               result["http_payment_setup"] == 200 && result["http_pay"] == 200 && result["psp_reference"].to_s.start_with?("pi_"))
    check.call("B  NON-alcohol create_order with NO KYC → 200 directly (positive control)",
               result["http_nonalcohol_no_kyc"] == 200 && !result["nonalcohol_order_id"].to_s.empty?)
    check.call("R1 forged age attestation rejected at /agents/kyc → 403",
               result["http_forged_kyc_submit"] == 403)
    check.call("R2 alcohol create_order after the forged submit still blocked → 403",
               result["http_alcohol_after_forged"] == 403)
    # THE FAIL-CLOSED BOOLEAN. A genuinely broker-signed attestation
    # whose age_over_18 is the STRING "true" is ACCEPTED as an attestation and
    # grants NOTHING — so the agent cleared in PART A loses its clearance and
    # the alcohol order it just paid for is refused on a retry. Presence of a
    # row is the grant, and only the JSON boolean writes one.
    check.call("R3 a broker-signed attestation with \"true\" as a STRING grants NO attribute",
               result["http_spelling_kyc_submit"] == 200 && (result["spelling_attributes"] || {}).empty?)
    check.call("R3 the alcohol gate fails CLOSED on it — back to 403 for an agent that HAD passed",
               result["http_alcohol_after_spelling"] == 403)

    if failures.empty?
      puts "\n  All age-gate assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end check:agecheck ──────────────────────────────────────────────────────

  desc <<~DESC
    The shop's own two transitions — the courier leaving and the basket arriving.

    WHY IT IS A TASK AND NOT PART OF check:shop. The courier departs ten to
    fifteen minutes before a window that is itself hours away, so no flow that
    drives the wire can reach either transition: a suite that waited would be a
    suite nobody runs. `courier_lead_seconds` is configuration exactly so this
    task can pin it, and the orders below are seeded onto a window that has
    already opened, which is what makes both departures due at once.
  DESC
  task delivery: :environment do
    failures = []
    check = lambda { |label, ok|
      puts(ok ? "  ✓  #{label}" : "  ✗  #{label}")
      failures << label unless ok
    }

    store = Kiosk::Server::EventStore.new
    Kiosk.configure { |c| c.event_store = store }

    user = User.first || abort("run demo:setup first — no users seeded")
    zone = DeliverySlots.default_zone
    # A lead LONGER than the distance to the window, so the departure is due
    # and the arrival is not. That is not a contrivance: it is an order placed
    # for the very next window, which is exactly when a courier leaves at once.
    lead   = 2 * 60 * 60
    window = Time.current + (60 * 60)
    Rails.configuration.x.getgrocery.courier_lead_seconds = lead

    # RE-RUNNABLE, because a task that only passes the first time is a task
    # nobody trusts the second. These rows carry a total no seed and no flow
    # writes, so clearing exactly that clears this task's own leftovers.
    marker_cents = 991_100
    Order.where(total_cents: marker_cents).delete_all

    seed = lambda { |slot_at|
      Order.create!(user: user, status: Order::PAID, total_cents: marker_cents,
                    slot_at: slot_at, timezone: zone.name,
                    address: "1 Demo Street, Dublin 2")
    }

    puts "\n── the courier LEAVES, and the ETA is the published window ──"
    order = seed.call(window)
    head  = store.head
    CourierDispatchJob.arm!(order.id)
    order.reload
    check.call("dispatch_at is the window minus the shop's lead",
               order.dispatch_at && (window - order.dispatch_at).round == lead)
    check.call("status is out_for_delivery", order.status == Order::OUT_FOR_DELIVERY)
    left = store.since(user.id, head).find { |e| e["subject"] == order.id }
    check.call("one order_delivery event, status=out_for_delivery",
               left && left["topic"] == "order_delivery" &&
               left["data"]["status"] == "out_for_delivery")
    check.call("the event carries the window as the ETA",
               left && left["data"]["eta"] == window.utc.iso8601)
    check.call("…with the clock it was quoted on, and a human's spelling of it",
               left && left["data"]["timezone"] == zone.name &&
               left["data"]["eta_label"] == DeliverySlots.label(window, zone))
    # THE BASKET HAS NOT ARRIVED YET, and nothing said it had. The arrival is
    # the window itself, which is an hour off.
    check.call("the departure alone pushes no `delivered`",
               store.since(user.id, head).none? { |e| e["data"]["status"] == "delivered" })

    puts "\n── a basket the courier is carrying cannot be moved ──"
    # Two refusals live in `reschedulable` and they are not the same one: «you
    # have already moved this once» is a quota, «the courier has left» is the
    # physical world. This asserts the second.
    check.call("reschedulable excludes an order out for delivery",
               !Order.reschedulable.where(id: order.id).exists?)

    puts "\n── the basket ARRIVES ──"
    head_arrival = store.head
    OrderDeliveredJob.new.perform(order.id)
    order.reload
    check.call("status is delivered", order.status == Order::DELIVERED)
    arrived = store.since(user.id, head_arrival).find { |e| e["subject"] == order.id }
    check.call("one order_delivery event, status=delivered",
               arrived && arrived["data"]["status"] == "delivered")

    head_again = store.head
    OrderDeliveredJob.new.perform(order.id)
    check.call("a delivered basket does not arrive twice",
               store.since(user.id, head_again).none? { |e| e["subject"] == order.id })

    puts "\n── a window the shop has not reached yet ──"
    # Arming is not departing. A courier is due and the row says when, in a
    # column an operator can read without opening a queue.
    future = seed.call(Time.current + (2 * 24 * 60 * 60))
    CourierDispatchJob.arm!(future.id)
    future.reload
    check.call("a window two days out arms a courier and does NOT depart",
               future.status == Order::PAID && future.dispatch_at > Time.current)

    # AND THE OLD SCHEDULE ARRIVING AFTER A MOVE DEPARTS NOTHING. Re-arming
    # rewrote `dispatch_at`; this run re-reads it, finds it in the future, and
    # hands itself back to the new schedule rather than sending a courier a day
    # early.
    head_stale = store.head
    CourierDispatchJob.new.perform(future.id)
    future.reload
    check.call("a stale run against a future window departs nothing",
               future.status == Order::PAID)
    check.call("…and pushes no event",
               store.since(user.id, head_stale).none? { |e| e["subject"] == future.id })

    puts ""
    if failures.empty?
      puts "  All assertions passed."
    else
      puts "  FAILED: #{failures.size} assertion(s) — #{failures.join(", ")}"
      exit 1
    end
  end
  # ── end check:delivery ──────────────────────────────────────────────────────
end
