# frozen_string_literal: true

# philslist demo orchestration (NON-COMMERCE classifieds board). Sub-tasks:
#
#   rake demo:setup        idempotent db:drop / create / schema:load / seed
#   rake demo:walkthrough  boots the server, runs the browse→post→edit→close
#                          curl showcase (NO payment step), tears down
#   rake demo:isolation    adversarial cross-owner denial test (write denial)
#   rake demo:register     registration-PoW demo (no-proof 402 → solve → 201)
#   rake demo:binding      account-binding walkthrough (claim ceremony over the
#                          real Devise session + link-code redeem + unlink)
#   rake demo:redteam      adversarial regression battery against the live surface
#   rake demo:schema       self-discovery + NOT-ONLY-COMMERCE proof (pay absent)
#   rake demo              setup + walkthrough end-to-end
#
# The walkthrough lives in bin/demo (POSIX shell) so it's debuggable
# without going through Rake.

# ── Flow-driver runner — READ THE CHILD'S EXIT STATUS (K-1043) ────────────────
#
# Every flow-driver invocation in this file goes through here, for the one line
# the shape it replaced did not have: `status.success?`.
#
# That shape was a bare backtick capture feeding
# `JSON.parse(raw.lines.grep(/^\{/).last || raw)`, and it never consulted `$?`.
# A task's verdict therefore rested entirely on "did a line starting with `{`
# appear", and two failures fall out of that. It FAILED OPEN: a driver that
# printed its JSON line and THEN died was reported as a PASS — and that is not
# hypothetical, kiosk-demo-getgrocery/script/rls_proof.rb prints its summary
# line before `exit 1` on a breach. And when a driver died BEFORE printing one,
# the operator's headline was a JSON parse error naming the driver's FIRST line
# of output, which sends the reader to the wrong file instead of showing the
# driver's own message.
#
# So: status first, and on a non-zero child the abort quotes the child's own
# last output line. Only then is the JSON parsed. `Open3.capture2e` keeps the
# merged stdout+stderr interleaving the transcript always had, and hands back
# the status the backticks threw away.
#
# NOT widened to the sibling `psql -X -tAc` probes in this file, deliberately:
# those capture with `2>&1` into a value that is then COMPARED, so a psql error
# lands in the string, fails its assertion and goes red. They fail closed.
def philslist_run_flow(flow_rb, env_str = "", env: {}, runner: "ruby")
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

# ── shared server-spawn/readiness helper ──────────────────────────────────────
def philslist_boot_server(log:, port:, extra_env: {})
  require "net/http"
  require "uri"
  server_url = "http://127.0.0.1:#{port}"
  File.truncate(log, 0) if File.exist?(log)
  pid = spawn(
    { "KIOSK_ISSUER" => server_url }.merge(extra_env),
    "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
    out: log, err: log,
  )
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
  unless ready
    # K-712e: reap the server WE spawned before leaving. The abort used to fire
    # here with `pid` known only to this method — every caller registers its
    # cleanup on the value this method RETURNS, so on a readiness failure the
    # `rails s` outlived the run and held the port against the next one. The
    # caller's own `ensure`/`at_exit` cannot help: it never received a pid.
    begin
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    abort "Server did not become ready — see #{log}"
  end
  puts "  Server up at #{server_url}"
  [pid, server_url]
end

namespace :demo do
  desc "Create + load schema + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    # Path C: schema_format = :sql, so db:schema:load loads structure.sql
    # directly (no RLS). Use db:schema:load instead of db:migrate so the
    # canonical structure.sql (no ROW LEVEL SECURITY) is the source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc "Boot the server and run the demo walkthrough (browse→post→edit→close)."
  task :walkthrough do
    exec File.expand_path("../../bin/demo", __dir__)
  end

  # ---------------------------------------------------------------------------
  desc <<~DESC
    Adversarial cross-owner isolation test.

    Runs demo:setup (clean DB + seed), boots the server, runs script/isolation_flow.rb
    with the two seeded principals (Alice and Bob) — each one EARNED through the
    shipped binding ceremony, not a token the driver wrote down (T-104) — and
    asserts all cross-owner denial properties:

      Assertion 1 (cross-owner browse): browse_listings returns BOTH owners'
        open listings to Bob (open board — positive control).
      Assertion 2a (exclusion): Bob's my_listings does NOT contain Alice's listing.
      Assertion 2b (positive control): Bob's my_listings DOES contain Bob's own.
      Assertion 3 (cross-owner WRITE denial): Bob edit_listing on Alice's
        listing → 403. This is the assertion stylish marks N/A; here it is
        the headline.
      Assertion 4 (cross-owner WRITE denial): Bob close_listing on Alice's
        listing → 403.
      Assertion 5 (the principal is not an input): Bob post_listing with a
        forged owner_id arg (Alice's UUID) → 400 bad_request naming owner_id,
        refused by the published input_schema before the handler runs; and
        Bob's legitimate listing has DB owner_id == Bob and
        created_by_agent_id == the agent id /auth/register MINTED for Bob, so
        both ownership and attribution come from the token.
      Assertion 6 (the departure is DECLARED — K-949/ADR-0028): the open board
        is a §7.2 departure and must say so on the wire. 6a reads the
        UNAUTHENTICATED catalog and requires browse_listings to publish
        `reach: published` and my_listings `reach: principal`. 6b is the half a
        comment cannot satisfy: every query the catalog publishes as
        `principal` and that takes no required argument is called AS BOB, and
        none of the answers may carry Alice's listing — so deleting
        `reach :published` moves browse_listings into that probe set and fails
        here with Alice's row in hand.

    Exits 0 if all assertions hold; exits 1 on failure. A red assertion = a real
    isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "json"
    require "shellwords"
    port = ENV.fetch("PORT", "3006")
    log  = "/tmp/kiosk-philslist-isolation.log"
    db   = "kiosk_philslist_development"

    # The two seeded humans behind the two assistants (db/seeds.rb). Since
    # T-104 the driver EARNS each principal through the shipped ceremony —
    # register → the human's Devise sign-in → link → claim — so it needs real
    # credentials, and they travel as env the way demo:binding's do rather than
    # as literals inside script/isolation_flow.rb.
    alice_email   = "alice@example.com"
    bob_email     = "bob@example.com"
    demo_password = "philslist-demo-password"

    puts "\n── Starting philslist (isolation test) ──"
    server_pid, server_url = philslist_boot_server(log: log, port: port)
    at_exit do
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    flow_rb = File.expand_path("../../script/isolation_flow.rb", __dir__)
    puts "\n── Running script/isolation_flow.rb (adversarial cross-owner) ──"
    env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{server_url.shellescape} " \
          "ALICE_EMAIL=#{alice_email.shellescape} BOB_EMAIL=#{bob_email.shellescape} " \
          "DEMO_PASSWORD=#{demo_password.shellescape}"
    result = philslist_run_flow(flow_rb, env)

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_b        = result["user_id_b"]
    agent_id_b       = result["agent_id_b"]
    alice_listing_id = result["alice_listing_id"]
    bob_listing_id   = result["bob_listing_id"]
    browse_ids       = result["browse_ids"] || []
    b_my_ids         = result["b_my_ids"]   || []
    edit_rc          = (result["cross_owner_edit"]  || []).first
    close_rc         = (result["cross_owner_close"] || []).first
    forged_refusal   = result["forged_refusal"] || []
    owner_probe_id   = result["owner_probe_listing_id"]

    # Assertion 1: browse is cross-owner.
    if browse_ids.include?(alice_listing_id) && browse_ids.include?(bob_listing_id)
      puts "  OK  Assertion 1: browse_listings returns BOTH owners' listings (cross-owner open board)"
    else
      failures << "browse_listings is not cross-owner: #{browse_ids.inspect} missing Alice #{alice_listing_id} or Bob #{bob_listing_id}"
      puts "  x  Assertion 1 FAILED: browse_listings not cross-owner"
    end

    # Assertion 2a: exclusion.
    if b_my_ids.include?(alice_listing_id)
      failures << "ISOLATION HOLE: Bob's my_listings contains Alice's listing #{alice_listing_id}"
      puts "  x  Assertion 2a FAILED: Bob sees Alice's listing in my_listings — isolation hole"
    else
      puts "  OK  Assertion 2a: Bob's my_listings excludes Alice's listing (app-layer isolation)"
    end

    # Assertion 2b: non-vacuous positive control.
    if b_my_ids.include?(bob_listing_id)
      puts "  OK  Assertion 2b: Bob's my_listings includes Bob's own #{bob_listing_id} (positive control)"
    else
      failures << "Bob's my_listings missing Bob's own #{bob_listing_id}; got #{b_my_ids.inspect} — vacuous exclusion"
      puts "  x  Assertion 2b FAILED: Bob's my_listings missing his own listing — positive control failed"
    end

    # Assertion 3: cross-owner edit → 403.
    if edit_rc == 403
      puts "  OK  Assertion 3: Bob edit_listing on Alice's listing → 403 (cross-owner WRITE denial)"
    else
      failures << "cross-owner edit_listing returned #{edit_rc.inspect}, want 403"
      puts "  x  Assertion 3 FAILED: cross-owner edit returned #{edit_rc.inspect} (want 403)"
    end

    # Assertion 4: cross-owner close → 403.
    if close_rc == 403
      puts "  OK  Assertion 4: Bob close_listing on Alice's listing → 403 (cross-owner WRITE denial)"
    else
      failures << "cross-owner close_listing returned #{close_rc.inspect}, want 403"
      puts "  x  Assertion 4 FAILED: cross-owner close returned #{close_rc.inspect} (want 403)"
    end

    # Assertion 5a: the forged owner_id is REFUSED by the published contract.
    forged_rc, forged_code, forged_detail = forged_refusal
    if forged_rc == 400 && forged_code == "bad_request" && forged_detail.to_s.include?("owner_id")
      puts "  OK  Assertion 5a: forged owner_id → 400 bad_request naming owner_id " \
           "(refused by input_schema before the handler runs)"
    else
      failures << "forged owner_id not refused: #{forged_refusal.inspect}, want [400, \"bad_request\", …owner_id…]"
      puts "  x  Assertion 5a FAILED: forged owner_id → #{forged_refusal.inspect}"
    end

    # Assertion 5b: ownership comes from the TOKEN — DB owner_id == Bob.
    db_owner = `psql -X -d #{db} -tAc "SELECT owner_id FROM listings WHERE id = '#{owner_probe_id}'" 2>&1`.strip
    if db_owner == user_id_b
      puts "  OK  Assertion 5b: DB listings.owner_id == Bob (#{user_id_b}) — ownership is taken from the identity"
    else
      failures << "owner not taken from identity: DB owner_id #{db_owner.inspect}, want Bob #{user_id_b}"
      puts "  x  Assertion 5b FAILED: listing owner_id #{db_owner.inspect} (want Bob #{user_id_b})"
    end

    # Assertion 5c: ATTRIBUTION comes from the identity too, and the identity is
    # one the engine minted. `created_by_agent_id` is written from the acting
    # agent (post_listing_operation.rb) and is unwritable from the wire; the id
    # it must equal is the uuid `/auth/register` handed this run's assistant.
    # Before T-104 a driver chose its own agent id, so this column could only
    # ever agree with the driver's own literal.
    db_agent = `psql -X -d #{db} -tAc "SELECT created_by_agent_id FROM listings WHERE id = '#{owner_probe_id}'" 2>&1`.strip
    if db_agent == agent_id_b
      puts "  OK  Assertion 5c: DB listings.created_by_agent_id == Bob's MINTED agent id (#{agent_id_b})"
    else
      failures << "attribution not taken from identity: DB created_by_agent_id #{db_agent.inspect}, want #{agent_id_b.inspect}"
      puts "  x  Assertion 5c FAILED: created_by_agent_id #{db_agent.inspect} (want #{agent_id_b.inspect})"
    end

    # Assertion 6a: the catalog PUBLISHES the reach of both board verbs.
    reach_by_verb = result["reach_by_verb"] || {}
    want_reach    = { "browse_listings" => "published", "my_listings" => "principal" }
    got_reach     = reach_by_verb.slice(*want_reach.keys)
    if got_reach == want_reach
      puts "  OK  Assertion 6a: the catalog declares browse_listings reach=published, " \
           "my_listings reach=principal (the §7.2 departure is published, not implied)"
    else
      failures << "declared reach is #{got_reach.inspect}, want #{want_reach.inspect}"
      puts "  x  Assertion 6a FAILED: declared reach #{got_reach.inspect} (want #{want_reach.inspect})"
    end

    # Assertion 6b: nothing claiming `principal` reach returns Alice's row.
    #
    # NON-VACUITY IS ASSERTED, NOT ASSUMED: an empty probe set would make the
    # loop below pass while checking nothing, which is precisely how a green
    # isolation report gets manufactured. my_listings is a principal-reach
    # no-argument query, so the set is never legitimately empty here.
    probe = result["principal_probe"] || []
    if probe.empty?
      failures << "the principal-reach probe set is EMPTY — nothing was checked"
      puts "  x  Assertion 6b FAILED: no principal-reach verb was probed (vacuous)"
    else
      leaked = probe.select { |(_name, prc, body)| prc == 200 && body.to_s.include?(alice_listing_id.to_s) }
      if leaked.empty?
        puts "  OK  Assertion 6b: #{probe.length} principal-reach verb(s) probed as Bob " \
             "(#{probe.map(&:first).join(', ')}); none returned Alice's listing"
      else
        failures << "UNDECLARED CROSS-PRINCIPAL READ: #{leaked.map(&:first).join(', ')} " \
                    "claim reach=principal but returned Alice's listing #{alice_listing_id}"
        puts "  x  Assertion 6b FAILED: #{leaked.map(&:first).join(', ')} claim principal reach " \
             "and returned Alice's listing"
      end
    end

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer cross-owner isolation holds."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
end

desc "End-to-end philslist demo: setup the DB then run the walkthrough."
task demo: ["demo:setup", "demo:walkthrough"]

namespace :demo do
  desc <<~DESC
    Registration-PoW demo.

    With no payment gate, the registration PoW is a FREE-board anti-spam toll.
    Register-PoW is ALWAYS ON (wired in the app config, no env flag), so the
    default server already gates registration. Runs script/register_flow.rb: register
    with no proof → 402; solve the Equihash challenge and resubmit → 201; the
    fresh token posts a listing → 200. Requires python3 + numpy.
  DESC
  task register: :setup do
    require "json"; require "shellwords"
    abort "numpy not found (pip install numpy)" unless system("python3 -c 'import numpy' 2>/dev/null")

    port    = ENV.fetch("PORT", "3006")
    log     = "/tmp/kiosk-philslist-register.log"
    flow_rb = File.expand_path("../../script/register_flow.rb", __dir__)
    failures = []

    server_pid, server_url = philslist_boot_server(log: log, port: port)
    puts "  (registration PoW active)"
    begin
      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{server_url.shellescape}"
      result = philslist_run_flow(flow_rb, env)

      puts "\n══ Registration PoW assertions ══"
      check = lambda do |label, ok|
        if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
      end
      check.call("register without proof → 402",     result["http_register_no_pow"] == 402)
      check.call("register with proof → 201",         result["http_register_solved"] == 201)
      check.call("solved 1 proof",                    result["proofs_solved"].to_i >= 1)
      check.call("fresh token posts a listing → 200", result["http_post"] == 200 && !result["listing_id"].to_s.empty?)
      check.call("bad category_slug → clean 400 (not 500)", result["http_post_bad_cat"] == 400)
      check.call("bad-category 400 names every valid category slug", result["bad_cat_lists_valid"] == true)
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
    Account-binding walkthrough — the binding ceremony + MULTI-ACCOUNT proof.

    Boots the server and runs script/binding_flow.rb, which drives BOTH sides of the
    ceremony over plain HTTP:

      FIRST CONTACT (claim): an assistant with a fresh key opens the claim
      ceremony; the human signs in through the REAL Devise form
      (/users/sign_in — cookie + CSRF dance), approves on the verify page, the
      assistant's possession-proof poll mints a token bound to the human's
      account, and it POSTS A LISTING there.

      HOUSEHOLD (multi-account): the signed-in human mints a link code, a
      SECOND assistant redeems it, sees the SAME account's listings (assistant
      1's listing), and can edit it — a household with separate assistants. The
      human then unlinks the first assistant — its login 404s from that moment
      while the second keeps working.

    Exits 0 if every assertion holds; exits 1 on failure.
  DESC
  task binding: :setup do
    require "json"; require "shellwords"

    port    = ENV.fetch("PORT", "3006")
    log     = "/tmp/kiosk-philslist-binding.log"
    flow_rb = File.expand_path("../../script/binding_flow.rb", __dir__)
    db      = "kiosk_philslist_development"
    failures = []

    # The seeded account holder (db/seeds.rb) — Alice approves the link.
    holder_id       = "00000000-0000-0000-0000-000000000001"
    holder_email    = "alice@example.com"
    holder_password = "philslist-demo-password"

    puts "\n── Starting philslist (account-binding walkthrough) ──"
    server_pid, server_url = philslist_boot_server(log: log, port: port)
    begin
      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{server_url.shellescape} " \
            "HOLDER_ID=#{holder_id.shellescape} HOLDER_EMAIL=#{holder_email.shellescape} " \
            "HOLDER_PASSWORD=#{holder_password.shellescape}"
      result = philslist_run_flow(flow_rb, env)

      puts "\n══ Account-binding assertions ══"
      check = lambda do |label, ok|
        if ok then puts "  OK  #{label}" else failures << label; puts "  FAIL  #{label}" end
      end
      check.call("human signed in via the real Devise form",        result["human_signed_in"] == true)
      check.call("device_authorization carries the RFC 8628 fields", result["da_fields"] == true)
      check.call("poll before approval → authorization_pending",     result["pending"] == [400, "authorization_pending"])
      check.call("human approve on the verify page → 200",           result["approve"] == 200)
      check.call("minted token is bound to the human's account",     result["bound_user"] == true)
      check.call("assistant 1 posts a listing as the account → 200", result["wire_post"] == 200)
      check.call("assistant 1 sees its listing in my_listings",      result["a1_sees_listing"] == true)
      check.call("manage-assistants page (session channel) → 200",   result["manage_page"] == 200)
      check.call("manage page lists the bound assistant",            result["manage_lists_a1"] == true)
      check.call("link-code mint (session channel) → 201",           result["link_mint"] == 201)
      check.call("link-code redeem binds to the SAME account",       result["link_claim"] == [201, true])
      check.call("assistant 2 sees assistant 1's listing (household)", result["a2_sees_listing"] == true)
      check.call("assistant 2 can EDIT the household listing → 200",  result["a2_edit"] == 200)
      # 204, not 200: unlink withdrew its undocumented `{ok: true}` body (K-870);
      # protocol.md §6.2 states the 204 beside link's and claim's responses.
      check.call("unlink assistant 1 → 204 (no body)",               result["unlink"] == 204)
      # K-835: the TOKEN half of spec §6.3/§15.4, not just the login half —
      # including a token minted in the same wall-clock second as the unlink,
      # which used to survive for its full hour. `unlink_same_second` reports
      # whether the run actually landed inside that aperture; the refusals are
      # required either way.
      check.call("assistant 1's held token after unlink → 401",      result["a1_token_after_unlink"] == 401)
      check.call("assistant 1's same-second token after unlink → 401", result["a1_fresh_token_after_unlink"] == 401)
      check.call("…and it cannot WRITE either → 401",                result["a1_fresh_token_write_after_unlink"] == 401)
      check.call("assistant 2's token is untouched → 200",           result["a2_token_still_works"] == 200)
      puts "  (unlink aperture exercised in the same wall-clock second: #{result["unlink_same_second"]})"
      check.call("assistant 1 login after unlink → 404",             result["login_a1_after_unlink"] == 404)
      check.call("assistant 2 login still works → 200",              result["login_a2_still_works"] == 200)

      # DB ground truth: both assistants bound to the human, listing owned by the human.
      agent1 = result["agent_id_1"].to_s
      agent2 = result["agent_id_2"].to_s
      bound1 = `psql -X -d #{db} -tAc "SELECT user_id FROM kiosk.agents WHERE id = '#{agent1}'" 2>&1`.strip
      bound2 = `psql -X -d #{db} -tAc "SELECT user_id FROM kiosk.agents WHERE id = '#{agent2}'" 2>&1`.strip
      check.call("DB kiosk.agents.user_id for assistant 1 == the human (#{holder_id})", bound1 == holder_id)
      check.call("DB kiosk.agents.user_id for assistant 2 == the human (household)",    bound2 == holder_id)
      listing_owner = `psql -X -d #{db} -tAc "SELECT owner_id FROM listings WHERE id = '#{result["listing_id"]}'" 2>&1`.strip
      check.call("DB listings.owner_id for the posted listing == the human",  listing_owner == holder_id)
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All account-binding assertions PASSED (multi-account household proved)."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end

namespace :demo do
  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery — attacks philslist's live surface.

    Boots the server and runs script/redteam_suite.rb, asserting each attack is BLOCKED:

      BLOCKED  CrossTenantRead   — Bob's my_listings excludes Alice's listing
      BLOCKED  ForgedUserId      — forged owner_id on post_listing refused (400)
      BLOCKED  CrossOwnerEdit    — Bob edit_listing on Alice's listing → 403
      BLOCKED  CrossOwnerClose   — Bob close_listing on Alice's listing → 403
      BLOCKED  MalformedUuidArg  — a malformed listing_id on edit/close → 400
               bad_request, with no SQL internals in the message
      BLOCKED  MissingAuth       — request with no Authorization → 401
      BLOCKED  GarbageToken      — unparseable bearer token → 401
      BLOCKED  SelfAssertedTokenForgery — a self-asserted
               `agent:u-…:a-…:r-owner` bearer naming a real account resolves to
               NO identity (401 on read AND write) in the SAME environment this
               suite drives, while a genuinely-bound token is answered
      BLOCKED  UnknownQuery      — unregistered query name → 404
      BLOCKED  UnknownAction     — unregistered action name → 404
      BLOCKED  RetiredWire       — the deleted 0.3 POST /kiosk/{query,run} are the
               ordinary 404 an authenticated caller gets, 401 without a bearer:
               no privileged endpoint left to attack either way
      BLOCKED  MethodMismatch    — a GET at an action's path is 405 + Allow: POST,
               never a silent 404
      BLOCKED  OutOfEnumFilterIsNotSilentlyReinterpreted — a browse_listings
               `category_slug` outside the LIVE categories table is a typed 400
               naming the sections that exist, never a 200 answering a
               different question
      BLOCKED  LikeMetacharactersAreEscaped — a `_` in `keyword` matches an
               UNDERSCORE, not any character: LIKE metacharacters are escaped,
               so a search says what the caller asked
      BLOCKED  NoSellerPiiOnTheOpenBoard — the cross-owner board names sellers
               by an opaque `seller-<hex>` pseudonym derived from the account
               id, carries no account address anywhere in the response, and
               keeps ONE handle per seller across their listings
      BLOCKED  DeviceGrantRoleSelfSelection — the shared kiosk-redteam beat:
               the binding ceremony's unauthenticated opening request refuses
               `role`/`scope` at a DECLARED value as well as an invented one,
               and the role-less request still opens it (K-072, K-1128)

    Exits 0 when all are BLOCKED (0 BREACH); exits 1 on any BREACH. A BREACH =
    a real hole — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "shellwords"
    port = ENV.fetch("PORT", "3006")
    log  = "/tmp/kiosk-philslist-redteam.log"

    # The two seeded humans behind the battery's principals (db/seeds.rb): since
    # T-104 the suite EARNS them through the shipped ceremony instead of writing
    # tokens down, so it needs credentials, passed as env like demo:binding's.
    alice_email   = "alice@example.com"
    bob_email     = "bob@example.com"
    demo_password = "philslist-demo-password"

    puts "\n── Starting philslist (redteam battery) ──"
    server_pid, server_url = philslist_boot_server(log: log, port: port)
    at_exit do
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    suite_rb = File.expand_path("../../script/redteam_suite.rb", __dir__)
    puts "\n── Running script/redteam_suite.rb ──"
    env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{server_url.shellescape} " \
          "ALICE_EMAIL=#{alice_email.shellescape} BOB_EMAIL=#{bob_email.shellescape} " \
          "DEMO_PASSWORD=#{demo_password.shellescape}"
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
    Self-discovery + NOT-ONLY-COMMERCE proof — verifies the schema verb AND the
    discovery documents over HTTP.

    Boots the server, authenticates a seeded principal, calls GET /kiosk/schema,
    /.well-known/kiosk.json, /agents.json, /agents.txt, and asserts:
      • `GET /kiosk/schema` answers 200 with NO Authorization header (public since T-094)
      • the MODULE set lives in /.well-known/kiosk.json `capabilities` (`verbs` dropped, T-095)
      • capabilities is the MODULE set schema/queries/actions
      • schema.queries includes browse_listings and my_listings
      • schema.actions includes post_listing/edit_listing/close_listing
      • every query/action entry carries a non-empty description
      • the DISCOVERY capabilities do NOT include `pay` (the not-only-commerce
        proof — pay drops out with no payment_provider)
      • agents.json carries NO payments block
      • agents.txt carries NO `Protocols: ap2` / `Payments:` directives

      • the `<link rel="kiosk">` tag AND the `Link: <…>; rel="kiosk"` header both name
        a VERSIONED cut — not the mutable `skill.md` alias — and both agree with the
        `skill` pin in /.well-known/kiosk.json (K-927, protocol.md §4.5)

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task schema: :setup do
    require "json"
    port = ENV.fetch("PORT", "3006")
    log  = "/tmp/kiosk-philslist-schema.log"

    puts "\n── Starting philslist (schema proof) ──"
    server_pid, server_url = philslist_boot_server(log: log, port: port)
    at_exit do
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    flow_rb = File.expand_path("../../script/schema_flow.rb", __dir__)
    puts "\n── Running script/schema_flow.rb ──"
    result = philslist_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{server_url}")

    puts "\n── Schema + discovery assertions ──"
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
    %w[/ /listings].each do |page|
      res = Net::HTTP.get_response(URI("#{server_url}#{page}"))
      advertised[%(<link rel="kiosk"> tag)] ||=
        res.body.to_s[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
      advertised[%(Link: <…>; rel="kiosk" header)] ||=
        res["Link"].to_s[/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
    end

    advertised.each do |what, url|
      if url.nil? || url.empty?
        failures << "#{what}: absent from #{%w[/ /listings].join(", ")} — §4.5's signal is not served"
        puts "  ✗  #{what} absent from #{%w[/ /listings].join(", ")}"
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

    # THE MODULE SET, at its one remaining home: `schema` published a
    # byte-identical copy as `verbs` until T-095 dropped it.
    %w[schema queries actions].each do |v|
      if capabilities.include?(v)
        puts "  ✓  capabilities includes #{v}"
      else
        failures << "capabilities missing #{v} (got #{capabilities.inspect})"
        puts "  ✗  capabilities missing #{v}"
      end
    end

    # Queries: browse_listings + my_listings.
    %w[browse_listings my_listings].each do |q|
      if queries.include?(q)
        puts "  ✓  schema.queries includes #{q}"
      else
        failures << "schema.queries missing #{q} (got #{queries.inspect})"
        puts "  ✗  schema.queries missing #{q}"
      end
    end

    # Actions: post/edit/close (NO flag_listing — cut).
    %w[post_listing edit_listing close_listing].each do |a|
      if actions.include?(a)
        puts "  ✓  schema.actions includes #{a}"
      else
        failures << "schema.actions missing #{a} (got #{actions.inspect})"
        puts "  ✗  schema.actions missing #{a}"
      end
    end

    # Descriptions non-empty.
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

    # T-042 / K-452: the primary read query (browse_listings) and primary action
    # (post_listing) advertise the machine-readable descriptor extensions.
    {
      query_specs  => %w[browse_listings],
      action_specs => %w[post_listing],
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

    # ── NOT-ONLY-COMMERCE: pay absent from the ADVERTISED capability set ──
    if capabilities.include?("pay")
      failures << "discovery capabilities advertise `pay` (got #{capabilities.inspect}) — philslist takes no payments"
      puts "  ✗  discovery capabilities include `pay` — must be ABSENT"
    else
      puts "  ✓  discovery capabilities do NOT include `pay` (#{capabilities.inspect}) — not-only-commerce proof"
    end
    %w[schema queries actions].each do |cap|
      if capabilities.include?(cap)
        puts "  ✓  discovery capabilities include #{cap}"
      else
        failures << "discovery capabilities missing #{cap} (got #{capabilities.inspect})"
        puts "  ✗  discovery capabilities missing #{cap}"
      end
    end

    if result["agents_json_has_payments"]
      failures << "agents.json carries a payments block — must be absent for a payment-less provider"
      puts "  ✗  agents.json carries a payments block"
    else
      puts "  ✓  agents.json carries NO payments block"
    end
    if result["agents_txt_has_ap2"] || result["agents_txt_has_payments"]
      failures << "agents.txt carries AP2/Payments directives — must be absent"
      puts "  ✗  agents.txt carries `Protocols: ap2` / `Payments:` directives"
    else
      puts "  ✓  agents.txt carries NO `Protocols: ap2` / `Payments:` directives"
    end

    if failures.empty?
      puts "\n  All schema + discovery assertions passed (pay ABSENT — not-only-commerce)."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:schema ────────────────────────────────────────────────────────
end
