# frozen_string_literal: true

# Kiosk demo orchestration. Sub-tasks:
#
#   rake demo:setup        idempotent db:drop / create / schema:load / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase,
#                          tears down
#   rake demo:isolation    adversarial cross-tenant denial test
#   rake demo:register     registration-PoW demo (no-proof 402 → solve → 201)
#   rake demo:binding      account-binding walkthrough (claim ceremony over the
#                          real Devise session + link-code redeem + unlink)
#   rake demo:roles        roles-from-IdP demo — owner-linked assistant sees
#                          the whole salon_calendar + forecast, a customer-linked
#                          one sees only its own bookings
#   rake demo:redteam      adversarial regression battery against the live surface
#   rake demo:schema       self-discovery proof over the schema verb
#   rake demo              setup + walkthrough end-to-end
#
# The walkthrough lives in bin/demo (POSIX shell) so it's debuggable
# without going through Rake.

# The seeded credentials the drivers need, written ONCE (K-712, K-838).
# `db/seeds.rb` OWNS these values; this file only re-states them so the
# subprocess drivers can be handed them as env. Four tasks used to re-type the
# same password literal and two re-typed the owner's address, so a seed change
# had four places to reach in one file and nothing said so.
DEMO_CREDENTIALS = {
  password:    "combette-demo-password",
  owner_email: "owner@combette.example",
  alice_email: "alice@example.com",
  bob_email:   "bob@example.com",
}.freeze

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
    Adversarial cross-tenant isolation test.

    Runs demo:setup (clean DB + seed), boots the server, runs script/isolation_flow.rb
    with the two seeded principals (Alice and Bob), and asserts all cross-tenant
    denial properties:

      Assertion 1 (exclusion): B's my_appointments does NOT contain A's appointment aA.
      Assertion 2 (the principal is not an input): B calls book_appointment with a
        forged user_id arg (A's UUID) -> 400 bad_request naming user_id, refused by
        the published input_schema before the handler runs; and on B's LEGITIMATE
        booking, ownership comes from the token. Verified by:
          - the forged call's status/code/detail (400 / bad_request / names user_id)
          - the appointment's DB user_id column == B's user_id (not A's)
          - A's my_appointments does NOT contain B's appointment
      Note: book_appointment takes salon_id (open catalogue); no user-owned
        resource target -> ownership-denial assertion does not apply to this surface.

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "json"
    require "shellwords"

    port = ENV.fetch("PORT", "3005")
    log  = "/tmp/kiosk-stylish-isolation.log"
    db   = "kiosk_stylish_development"

    # The two seeded humans behind the two assistants (db/seeds.rb). Since T-104
    # the driver EARNS each principal through the shipped ceremony — register →
    # the human's Devise sign-in → link → claim — so it needs real credentials,
    # and they travel as env the way demo:binding's do rather than as literals
    # inside script/isolation_flow.rb.
    alice_email   = DEMO_CREDENTIALS[:alice_email]
    bob_email     = DEMO_CREDENTIALS[:bob_email]
    demo_password = DEMO_CREDENTIALS[:password]

    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting stylish (isolation test) on #{server_url} ──"

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

    # ── run script/isolation_flow.rb ──────────────────────────────────────────
    flow_rb = File.expand_path("../../script/isolation_flow.rb", __dir__)
    puts "\n── Running script/isolation_flow.rb (adversarial cross-tenant) ──"
    env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape} " \
          "ALICE_EMAIL=#{alice_email.shellescape} BOB_EMAIL=#{bob_email.shellescape} " \
          "DEMO_PASSWORD=#{demo_password.shellescape}"
    raw = `#{env} bundle exec ruby #{flow_rb.shellescape} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "script/isolation_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
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
    forged_refusal   = result["forged_refusal"]   || []

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

    # ── Assertion 2a: the forged user_id is REFUSED by the published contract ──
    forged_rc, forged_code, forged_detail = forged_refusal
    if forged_rc == 400 && forged_code == "bad_request" && forged_detail.to_s.include?("user_id")
      puts "  OK  Assertion 2a: forged user_id → 400 bad_request naming user_id " \
           "(refused by input_schema before the handler runs)"
    else
      failures << "forged user_id not refused: #{forged_refusal.inspect}, want [400, \"bad_request\", …user_id…]"
      puts "  x  Assertion 2a FAILED: forged user_id → #{forged_refusal.inspect}"
    end

    # ── Assertion 2b: A's my_appointments excludes B's appointment ──
    if a_appt_ids_after.include?(appt_id_b)
      failures << "ISOLATION HOLE: A's my_appointments contains B's appointment #{appt_id_b} — cross-tenant leak"
      puts "  x  Assertion 2b FAILED: A sees B's appointment #{appt_id_b} — isolation hole"
    else
      puts "  OK  Assertion 2b: A's my_appointments excludes B's appointment #{appt_id_b}"
    end

    # ── Assertion 2c: ownership comes from the TOKEN — DB user_id on aB == B ──
    # The token is one this provider MINTED for B's assistant (T-104), so this
    # now says something a written-down bearer could not: the row's owner is the
    # account the shipped binding ceremony resolved, not a string B chose.
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM appointments WHERE id = '#{appt_id_b}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  OK  Assertion 2c: DB appointments.user_id for aB == user_id_b (#{user_id_b}) — ownership is taken from the identity"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB appointments.user_id for aB is A's user_id (#{user_id_a}) — ownership NOT taken from the identity"
      puts "  x  Assertion 2c FAILED: appointment belongs to A, not B"
    else
      failures << "Unexpected user_id for aB: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  x  Assertion 2c FAILED: unexpected user_id #{db_user_id.inspect} for aB"
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
    Registration-PoW demo.

    Register-PoW is ALWAYS ON (wired in the app config, no env flag), so the
    default server already gates registration. Runs script/register_flow.rb: register
    with no proof → 402; solve the Equihash challenge and resubmit →
    201; the fresh token queries `salons` → 200. Requires python3 + numpy.
  DESC
  task register: :setup do
    require "net/http"; require "uri"; require "json"; require "shellwords"

    abort "numpy not found (pip install numpy)" unless system("python3 -c 'import numpy' 2>/dev/null")

    port         = ENV.fetch("PORT", "3005")
    server_url   = "http://127.0.0.1:#{port}"
    log          = "/tmp/kiosk-stylish-register.log"
    flow_rb      = File.expand_path("../../script/register_flow.rb", __dir__)
    failures     = []

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => server_url },
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
      result = JSON.parse(json_line || raw) rescue abort("script/register_flow.rb produced no JSON:\n#{raw}")

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
  desc <<~DESC
    Account-binding walkthrough — both binding flows against the live app.

    Boots the server and runs script/binding_flow.rb, which drives BOTH sides of
    the ceremony over plain HTTP:

      FIRST CONTACT (claim): an assistant with a fresh key opens the claim
      ceremony; the human signs in through the REAL Devise form
      (/users/sign_in — cookie + CSRF dance, no fixtures), approves on the
      verify page, the assistant's possession-proof poll mints a token
      bound to the human's account, and it books an appointment there.

      HUMAN-INITIATED (link): the signed-in human mints a link code, a
      second assistant redeems it at /auth/claim and sees the same
      account's appointments; the human then unlinks the first assistant —
      its login 404s from that moment while the second keeps working.

    Exits 0 if every assertion holds; exits 1 on failure.
  DESC
  task binding: :setup do
    require "net/http"; require "uri"; require "json"; require "shellwords"

    port         = ENV.fetch("PORT", "3005")
    server_url   = "http://127.0.0.1:#{port}"
    log          = "/tmp/kiosk-stylish-binding.log"
    flow_rb      = File.expand_path("../../script/binding_flow.rb", __dir__)
    db           = "kiosk_stylish_development"
    failures     = []

    # The seeded account holder (db/seeds.rb) — Alice approves the link.
    holder_id       = "00000000-0000-0000-0000-000000000001"
    holder_email    = DEMO_CREDENTIALS[:alice_email]
    holder_password = DEMO_CREDENTIALS[:password]

    puts "\n── Starting stylish (account-binding walkthrough) on #{server_url} ──"

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => server_url },
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
      puts "  Server up at #{server_url}"

      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{server_url.shellescape} " \
            "HOLDER_ID=#{holder_id.shellescape} HOLDER_EMAIL=#{holder_email.shellescape} " \
            "HOLDER_PASSWORD=#{holder_password.shellescape}"
      raw = `#{env} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      json_line = raw.lines.grep(/^\{/).last
      puts raw.lines.reject { |l| l.start_with?("{") }.join
      puts json_line if json_line
      result = JSON.parse(json_line || raw) rescue abort("script/binding_flow.rb produced no JSON:\n#{raw}")

      puts "\n══ Account-binding assertions ══"
      check = lambda do |label, ok|
        if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
      end
      check.call("human signed in via the real Devise form",       result["human_signed_in"] == true)
      check.call("device_authorization carries the RFC 8628 fields", result["da_fields"] == true)
      check.call("poll before approval → authorization_pending",   result["pending"] == [400, "authorization_pending"])
      check.call("human approve on the verify page → 200",         result["approve"] == 200)
      check.call("minted token is bound to the human's account",   result["bound_user"] == true)
      check.call("wire verb (book_appointment) as the account → 200", result["wire_book"] == 200)
      check.call("assistant 1 sees its booking in my_appointments", result["a1_sees_booking"] == true)
      check.call("manage-assistants page (session channel) → 200", result["manage_page"] == 200)
      check.call("manage page lists the bound assistant",           result["manage_lists_a1"] == true)
      check.call("set spending cap via the manage page → 200",      result["manage_update"] == 200)
      check.call("re-rendered page shows the saved cap + label",    result["manage_cap_shown"] == true)
      check.call("link-code mint (session channel) → 201",         result["link_mint"] == 201)
      check.call("link-code redeem binds to the same account",     result["link_claim"] == [201, true])
      check.call("assistant 2 sees assistant 1's booking (same account)", result["a2_sees_booking"] == true)
      check.call("unlink assistant 1 → 200",                       result["unlink"] == 200)
      check.call("assistant 1 login after unlink → 404",           result["login_a1_after_unlink"] == 404)
      check.call("assistant 2 login still works → 200",            result["login_a2_still_works"] == 200)

      # DB ground truth: the ceremony's product is the key→account binding,
      # and the booking landed on the human's own row.
      agent1 = result["agent_id_1"].to_s
      bound_uid = `psql -X -d #{db} -tAc "SELECT user_id FROM kiosk.agents WHERE id = '#{agent1}'" 2>&1`.strip
      check.call("DB kiosk.agents.user_id for assistant 1 == the human (#{holder_id})", bound_uid == holder_id)
      db_cap = `psql -X -d #{db} -tAc "SELECT spending_cap_cents FROM kiosk.agents WHERE id = '#{agent1}'" 2>&1`.strip
      check.call("DB kiosk.agents.spending_cap_cents for assistant 1 == 12345 (set on the manage page)", db_cap == "12345")
      appt_uid = `psql -X -d #{db} -tAc "SELECT user_id FROM appointments WHERE id = '#{result["appointment_id"]}'" 2>&1`.strip
      check.call("DB appointments.user_id for the booking == the human",  appt_uid == holder_id)
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All account-binding assertions PASSED."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end

namespace :demo do
  # ── demo:roles ─────────────────────────────────────────────────────────────
  desc <<~DESC
    roles-from-IdP demo (Path A — indirect, via the bound human).

    Boots the server and runs script/roles_flow.rb. A salon OWNER signs in at
    /users/sign_in and links their assistant over that REAL Devise session; the
    assistant INHERITS the owner role — read off the provider's own
    `staff_role` column through `User#kiosk_role` — and `salon_calendar`
    returns the WHOLE book (every visitor's booking) + a FORECASTED revenue
    total (summed live from the actual bookings' prices). A CUSTOMER who signs
    in at the same form inherits the customer role and `salon_calendar` returns
    ONLY their own bookings and NO forecast. The role is sourced from the
    provider's IdP at link time, never self-selected by the agent. (No stylist
    roster — the menu is evergreen and infinite-capacity, so the contrast is
    owner=whole-book+forecast vs customer=own-only.)

    Asserts (with DB ground-truth on kiosk.agents.allowed_roles):
      • owner-agent allowed_roles == {owner}; token role == owner
      • owner salon_calendar carries a FORECAST summary
      • customer sign-in → role customer, NO forecast

    Exits 0 if all hold; exits 1 on failure. A red assertion = a real role
    gate hole: fix the app, not the test.
  DESC
  task roles: :setup do
    require "net/http"; require "uri"; require "json"; require "shellwords"

    port         = ENV.fetch("PORT", "3005")
    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url
    log          = "/tmp/kiosk-stylish-roles.log"
    flow_rb      = File.expand_path("../../script/roles_flow.rb", __dir__)
    db           = "kiosk_stylish_development"
    failures     = []

    owner_id    = "00000000-0000-0000-0000-0000000000a0"

    puts "\n── Starting stylish (roles-from-IdP demo) on #{server_url} ──"

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
          ready = true if Net::HTTP.get_response(URI("#{server_url}/.well-known/kiosk.json")).code.to_i == 200
        rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
          nil
        end
        break if ready
        sleep 1
      end
      abort "Server did not become ready — see #{log}" unless ready
      puts "  Server up at #{server_url}"

      # K-838: the driver reads its credentials from env like every sibling
      # driver does — db/seeds.rb owns them, and a seed change must not leave a
      # sign-in failure inside script/roles_flow.rb naming nothing.
      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape} " \
            "OWNER_EMAIL=#{DEMO_CREDENTIALS[:owner_email].shellescape} " \
            "CUSTOMER_EMAIL=#{DEMO_CREDENTIALS[:alice_email].shellescape} " \
            "DEMO_PASSWORD=#{DEMO_CREDENTIALS[:password].shellescape}"
      raw = `#{env} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      json_line = raw.lines.grep(/^\{/).last
      puts raw.lines.reject { |l| l.start_with?("{") }.join
      puts json_line if json_line
      result = JSON.parse(json_line || raw) rescue abort("script/roles_flow.rb produced no JSON:\n#{raw}")

      puts "\n══ roles-from-IdP assertions ══"
      check = lambda do |label, ok|
        if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
      end

      # DB ground-truth: the inherited role landed on the agent row.
      owner_roles = `psql -X -d #{db} -tAc "SELECT allowed_roles FROM kiosk.agents WHERE user_id = '#{owner_id}' AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1"`.strip
      check.call("DB owner-agent allowed_roles == {owner} (inherited from IdP)", owner_roles == "{owner}")

      # Token role reflects the inherited role (not self-selected).
      check.call("owner assistant token role == owner", result["owner_token_role"] == "owner")

      # The wire gate: owner sees the whole book + a forecast summary. The demo
      # seeds zero bookings, so the forecast is €0 until a visitor books — the
      # honest starting figure; what matters is that the summary is PRESENT and
      # is a live sum of real prices (not a fabricated number).
      check.call("owner salon_calendar carries a FORECAST summary", result["owner_sees_forecast"] == true)

      # ── The K-437 regression, now the ONLY path. Without User#kiosk_role the
      # Devise adapter resolves every real sign-in to roles.first (customer),
      # so the owner's token comes back "customer" and the forecast disappears.
      # There is no second channel left that could pass while this one fails.
      check.call("customer sign-in → token role == customer",      result["devise_customer_token_role"] == "customer")
      check.call("customer salon_calendar has NO forecast (owner-only)", result["devise_customer_sees_forecast"] == false)
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All roles-from-IdP assertions PASSED."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
  # ── end demo:roles ─────────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery — attacks stylish's live surface.

    Boots the server and runs script/redteam_suite.rb against the salon-booking
    surface (salons / my_appointments queries, book_appointment action),
    asserting each attack is BLOCKED:

      BLOCKED  CrossTenantRead  — B's my_appointments excludes A's appointment
      BLOCKED  ForgedUserId     — agent-supplied user_id in book args refused (400)
      BLOCKED  MissingAuth      — request with no Authorization → 401
      BLOCKED  GarbageToken     — unparseable bearer token → 401
      BLOCKED  UnknownQuery     — unregistered query name → 404
      BLOCKED  UnknownAction    — unregistered action name → 404
      BLOCKED  RetiredWire      — the deleted 0.3 POST /kiosk/query and
               POST /kiosk/run answer an ordinary 404 (no compatibility surface)
      BLOCKED  MethodMismatch   — a GET at an action's path → 405
               method_not_allowed with Allow: POST, never a silent 404
      BLOCKED  CustomerLinkCannotCarryOwnerRole — a customer signs in for real
               and mints a link; the bound token's role is customer, because
               the role is read off the human, never chosen
      BLOCKED  OwnerLinkIgnoresForgedClaimBody — an owner-linking assistant
               cannot smuggle a wider role into the claim body; the role comes
               from the IdP session, so the token stays owner
      BLOCKED  CustomerCalendarStaysOwnScoped — a customer's agent sees only its
               own bookings + no forecast in salon_calendar (role gate
               un-bypassable)
      BLOCKED  SelfAssertedTokenForgery — a self-asserted
               `agent:u-<owner>:a-…:r-owner` bearer resolves to NO identity
               (401 at salon_calendar AND book_appointment) in the SAME
               environment this suite drives, while the owner's
               genuinely-bound token still reaches the whole book + forecast
      BLOCKED  SelfAssertedStaffSessionForgery — a forged X-Staff-Session
               header naming the owner buys nothing; the owner's real Devise
               session still mints a link

    stylish has no payment or KYC surface, so the battery covers only the
    attacks the surface can actually exhibit. Exits 0 when all are BLOCKED;
    exits 1 on any BREACH. A BREACH = a real hole — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "net/http"
    require "shellwords"
    require "uri"

    port         = ENV.fetch("PORT", "3005")
    log          = "/tmp/kiosk-stylish-redteam.log"
    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url

    # The seeded humans the battery drives (db/seeds.rb). Since T-104 the suite
    # EARNS its customer principals through the shipped ceremony instead of
    # writing tokens down, so it needs credentials, passed as env the way
    # demo:binding's are.
    alice_email   = DEMO_CREDENTIALS[:alice_email]
    bob_email     = DEMO_CREDENTIALS[:bob_email]
    owner_email   = DEMO_CREDENTIALS[:owner_email]
    demo_password = DEMO_CREDENTIALS[:password]

    puts "\n── Starting stylish (redteam battery) on #{server_url} ──"

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

    suite_rb = File.expand_path("../../script/redteam_suite.rb", __dir__)
    puts "\n── Running script/redteam_suite.rb ──"
    env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape} " \
          "ALICE_EMAIL=#{alice_email.shellescape} BOB_EMAIL=#{bob_email.shellescape} " \
          "OWNER_EMAIL=#{owner_email.shellescape} DEMO_PASSWORD=#{demo_password.shellescape}"
    system("#{env} bundle exec ruby #{suite_rb.shellescape}")
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
      • `GET /kiosk/schema` answers 200 with NO Authorization header (public since T-094)
      • the MODULE set lives in /.well-known/kiosk.json `capabilities` (`verbs` dropped, T-095)
      • capabilities is the MODULE set schema/queries/actions and NOT events
      • schema.queries includes salons and my_appointments
      • schema.actions includes book_appointment
      • every query/action entry carries a non-empty description

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "net/http"
    require "uri"
    require "json"

    port         = ENV.fetch("PORT", "3005")
    log          = "/tmp/kiosk-stylish-schema.log"
    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting stylish (schema proof) on #{server_url} ──"

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

    query_specs  = result["schema_queries"] || []
    action_specs = result["schema_actions"] || []
    queries = query_specs.map  { |q| q["name"] }
    actions = action_specs.map { |a| a["name"] }
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
    %w[schema queries actions].each do |v|
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

    # Descriptions: every query/action must carry non-empty metadata
    # (bare-block registration served null description; schema is the agent's
    # only self-discovery surface).
    (query_specs + action_specs).each do |spec|
      name = spec["name"]
      desc = spec["description"]
      if desc.is_a?(String) && !desc.strip.empty?
        puts "  ✓  schema entry #{name} carries a description"
      else
        failures << "schema entry #{name} has null/blank description (got #{desc.inspect})"
        puts "  ✗  schema entry #{name} has null/blank description"
      end
    end

    # T-042 / K-452: the primary read query (service_menu) and primary action
    # (book_appointment) advertise the machine-readable descriptor extensions.
    {
      query_specs  => %w[service_menu],
      action_specs => %w[book_appointment],
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
  # ── end demo:schema ────────────────────────────────────────────────────────
end
