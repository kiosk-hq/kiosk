# frozen_string_literal: true

# tudu demo orchestration (MULTI-USER COLLABORATIVE todo app, NO payments).
# Sub-tasks:
#
#   rake demo:setup      idempotent db:drop / create / schema:load / seed
#   rake demo:collab     happy path: two agents, shared list via invite,
#                        attribution asserted
#   rake demo:link       W5 rebind + list-transfer (assistant_claimed hook)
#   rake demo:isolation  adversarial membership isolation (Mallory walled out)
#   rake demo:redteam    adversarial regression battery (0 BREACH)
#   rake demo:schema     self-discovery + NOT-ONLY-COMMERCE proof (pay absent)
#   rake demo            setup + collab end-to-end

# ── shared server-spawn/readiness helper ──────────────────────────────────────
def tudu_boot_server(log:, port:, extra_env: {})
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

# Run a one-JSON-line flow driver, return the parsed hash (aborts on bad JSON).
def tudu_run_flow(flow_rb, server_url, extra_env = {})
  env = { "SERVER_URL" => server_url, "KIOSK_ISSUER" => server_url }.merge(extra_env)
  raw = IO.popen(env, ["bundle", "exec", "ruby", flow_rb], err: [:child, :out], &:read)
  puts raw
  begin
    JSON.parse(raw.lines.grep(/^\{/).last || raw)
  rescue JSON::ParserError => e
    abort "#{File.basename(flow_rb)} did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
  end
end

namespace :demo do
  desc "Create + load schema + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    # Path C: schema_format = :sql, so db:schema:load loads structure.sql
    # directly (no RLS). Generate encrypted credentials on first run so the dev
    # secret_key_base exists (Devise sessions need it) — idempotent. Done
    # directly (NOT via `rails credentials:edit`): the credentials generator's
    # master-key step appends its own ignore block to .gitignore, silently
    # regrowing the K-629-unified file on every fresh-machine run (K-666); the
    # unified .gitignore already covers /config/master.key and /config/*.key.
    enc_path, key_path = "config/credentials.yml.enc", "config/master.key"
    if File.exist?(enc_path) && !File.exist?(key_path)
      # Same dead end as before this task existed: nothing can decrypt the enc.
      warn "#{enc_path} exists but #{key_path} is missing — cannot decrypt; " \
           "delete #{enc_path} and re-run demo:setup to regenerate both"
    elsif !File.exist?(enc_path)
      require "securerandom"
      require "active_support/encrypted_configuration"
      unless File.exist?(key_path)
        File.write(key_path, ActiveSupport::EncryptedFile.generate_key)
        File.chmod(0o600, key_path)
      end
      ActiveSupport::EncryptedConfiguration.new(
        config_path: enc_path, key_path: key_path,
        env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true,
      ).write("secret_key_base: #{SecureRandom.hex(64)}")
    end
    # db:schema:load, NOT db:migrate (K-712a): this task's own description and
    # the comment above both say schema:load, and under
    # `schema_format = :sql` (config/application.rb) `db:migrate` RE-DUMPS the
    # tracked db/structure.sql, so running demo:setup dirtied the worktree.
    # The canonical structure.sql is the source of truth, as in every sibling.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end
end

namespace :demo do
  desc <<~DESC
    Collaboration happy path — membership-based access + agent→agent invites.

    Two agents (Alice's + Bob's, each PoP-registered) share a list without any
    spec change: Alice's agent creates "Hike" and mints an invite; Bob's agent
    accepts it and joins as a member. Asserts the shared world:
      • both agents' my_lists include "Hike" (Bob reaches a list he does NOT own)
      • list_todos shows BOTH todos, each attributed to the agent that added it
      • list_members shows an owner + a member
  DESC
  task collab: :setup do
    port = ENV.fetch("PORT", "3007")
    log  = "/tmp/kiosk-tudu-collab.log"
    puts "\n── Starting tudu (collaboration happy path) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    at_exit { tudu_stop(server_pid) }

    flow = File.expand_path("../../script/collab_flow.rb", __dir__)
    puts "\n── Running script/collab_flow.rb ──"
    r = tudu_run_flow(flow, server_url)

    failures = []
    check = ->(label, ok) { ok ? puts("  OK  #{label}") : (failures << label; puts("  x  #{label}")) }
    puts "\n── Collaboration assertions ──"
    check.call("Alice's agent owns 'Hike' (my_lists role=owner)",        r["alice_sees_hike"])
    check.call("Bob's agent reaches 'Hike' as a MEMBER (invite worked)", r["bob_sees_hike"])
    check.call("accept_invite joined Bob to the list",                   r["accept_joined"] && r["accept_list_id"] == r["list_id"])
    check.call("invite returned a plaintext code once",                  r["invite_returned_code"])
    check.call("both todos are on the shared list (count == 2)",         r["shared_todo_count"] == 2)
    check.call("Alice's todo attributed to Alice's agent",              r["alice_todo_attributed"])
    check.call("Bob's todo attributed to Bob's agent",                 r["bob_todo_attributed"])
    check.call("list_members shows an owner AND a member",              r["has_owner"] && r["has_member"] && r["member_count"] == 2)

    if failures.empty?
      puts "\n  All collaboration assertions passed — membership-based sharing + attribution hold."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end

desc "End-to-end tudu demo: setup the DB then run the collaboration walkthrough."
task demo: ["demo:setup", "demo:collab"]

namespace :demo do
  desc <<~DESC
    W5 rebind + domain migration — the assistant_claimed hook, first real use.

    An assistant registers HEADLESS (its own account) and creates the "Hike"
    list; the human (Alice) mints a link code and the SAME key redeems it →
    REBIND: agent_id stable, principal remapped to Alice, and assistant_claimed
    migrates the list to Alice. Asserts the list moved (psql ground truth), the
    pre-link token's principal owns nothing after migration, the assistant
    re-logs in and sees the list under Alice, Alice's browser sees it too, and
    Alice ends with >=2 non-revoked agents. Then RE-LINKS the same, already-
    bound key: nothing transitions, so nothing may be migrated or destroyed
    (K-783 — that beat used to delete every membership Alice had).
  DESC
  task link: :setup do
    port = ENV.fetch("PORT", "3007")
    log  = "/tmp/kiosk-tudu-link.log"
    db   = "kiosk_tudu_development"
    holder_id       = "00000000-0000-0000-0000-000000000001"
    holder_email    = "alice@example.com"
    holder_password = "tudu-demo-password"

    puts "\n── Starting tudu (W5 rebind walkthrough) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    failures = []
    begin
      flow = File.expand_path("../../script/link_flow.rb", __dir__)
      puts "\n── Running script/link_flow.rb ──"
      r = tudu_run_flow(flow, server_url,
                        "HOLDER_ID" => holder_id, "HOLDER_EMAIL" => holder_email, "HOLDER_PASSWORD" => holder_password)

      check = ->(label, ok) { ok ? puts("  OK  #{label}") : (failures << label; puts("  x  #{label}")) }
      puts "\n── W5 rebind assertions ──"
      check.call("human signed in via the real Devise form",        r["human_signed_in"] == true)
      check.call("link code minted (session channel) → 201",        r["link_mint"] == 201)
      check.call("claim rebound the key to Alice (same agent_id)",   r["claim_status"] == 201 && r["claim_rebound_to_holder"] && r["claim_same_agent_id"])
      check.call("pre-link token revoked by the rebind (principal change ⇒ 401)", r["prelink_status"] == 401 && r["prelink_revoked"])
      # K-836: the same, for a token minted in the rebind's OWN wall-clock
      # second — the case the strict `iat < watermark` comparison used to let
      # through, and which the driver used to sidestep with a sleep.
      check.call("a pre-link token minted in the rebind's own second is revoked too (K-836)", r["same_second_prelink_status"] == 401 && r["same_second_prelink_revoked"])
      check.call("re-login mints a token whose sub is Alice",        r["relogin_sub_is_holder"])
      check.call("re-logged-in agent sees 'Hike' as owner under Alice", r["agent_sees_migrated_list"])
      check.call("Alice's browser session sees 'Hike'",             r["human_sees_migrated_list"])
      check.call("a SECOND assistant links to Alice (multi-agent)", r["second_bound_to_holder"])

      # K-783: re-linking an ALREADY-bound key transitions nothing, so it must
      # migrate nothing and destroy nothing. It used to delete every membership
      # Alice had — the lists stayed hers and she could no longer reach one.
      check.call("re-linking the already-bound key still answers 201, same agent_id, same holder",
                 r["relink_status"] == 201 && r["relink_same_agent_id"] && r["relink_still_holder"])
      check.call("the assistant still sees 'Hike' after the re-link (membership survived)", r["relink_keeps_list_access"])
      check.call("Alice's browser still sees BOTH 'Hike' and the seeded 'Flat 3B'", r["human_keeps_all_lists"])

      # T-082: the human UI's READ half no longer goes through the wire
      # dispatcher — /lists/:id runs ListAccess + the model projections directly.
      # Both answers are asserted, because the page has two: the roster, and the
      # refusal a non-member earns.
      check.call("Alice's browser reads the list's own page (members roster rendered)", r["human_reads_list_page"])
      check.call("a list Alice is not a member of redirects instead of rendering a roster", r["human_foreign_list_refused"])

      # DB ground truth: the list was migrated to Alice; Alice has >=2 live agents.
      list_owner = `psql -X -d #{db} -tAc "SELECT account_id FROM lists WHERE id = '#{r["list_id"]}'" 2>&1`.strip
      check.call("DB lists.account_id for 'Hike' == Alice (#{holder_id}) — assistant_claimed migrated it", list_owner == holder_id)
      agent_count = `psql -X -d #{db} -tAc "SELECT count(*) FROM kiosk.agents WHERE user_id = '#{holder_id}' AND revoked_at IS NULL" 2>&1`.strip
      check.call("DB: Alice has >=2 non-revoked agents (multi-agent identity)", agent_count.to_i >= 2)
      # The membership rows themselves, not just what a query renders: Alice
      # holds 'Hike' (migrated) and 'Flat 3B' (seeded) after the re-link.
      membership_count = `psql -X -d #{db} -tAc "SELECT count(*) FROM memberships WHERE account_id = '#{holder_id}'" 2>&1`.strip
      check.call("DB: Alice still holds >=2 memberships after the re-link (K-783 destroyed all of them)", membership_count.to_i >= 2)
    ensure
      tudu_stop(server_pid)
    end

    if failures.empty?
      puts "\n  All W5 rebind assertions passed — the assistant_claimed hook migrated the domain."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end

namespace :demo do
  desc <<~DESC
    Adversarial membership-isolation test (Mallory, a non-member).

    A third principal is walled out of a list she was never invited to, with a
    genuine-member positive control so the exclusions aren't vacuous:
      • Mallory's my_lists is EMPTY
      • Mallory list_todos / list_members on the private list → 403
      • forged account_id on Mallory's create_list REFUSED (400 bad_request
        naming it), and her legitimate list is hers in the DB (psql truth)
      • a used/garbage invite code → 403
      • POSITIVE CONTROL: the genuine member DOES see + read the list
      • after remove_member, the member's next read → 403 (access gone)
      • Assertion 8 (K-949/ADR-0028): the §7.2 DEPARTURE IS DECLARED. 8a reads
        the unauthenticated catalog and requires my_lists / list_todos /
        list_members to publish `reach: consented` and whoami `reach:
        principal`. 8b calls every principal-reach no-argument query AS THE
        MEMBER — who legitimately reaches the owner's list — and requires that
        none of them carry that list's id, so deleting a `reach :consented`
        moves the verb into the probe set and fails here.
  DESC
  task isolation: :setup do
    port = ENV.fetch("PORT", "3007")
    log  = "/tmp/kiosk-tudu-isolation.log"
    db   = "kiosk_tudu_development"

    puts "\n── Starting tudu (membership isolation test) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    at_exit { tudu_stop(server_pid) }

    flow = File.expand_path("../../script/isolation_flow.rb", __dir__)
    puts "\n── Running script/isolation_flow.rb ──"
    r = tudu_run_flow(flow, server_url)

    failures = []
    check = ->(label, ok) { ok ? puts("  OK  #{label}") : (failures << label; puts("  x  #{label}")) }
    puts "\n── Membership isolation assertions ──"
    check.call("Mallory's my_lists is EMPTY (member of nothing)", r["mallory_my_lists_empty"])
    check.call("Mallory list_todos on a non-member list → 403",   r["mallory_list_todos"] == 403)
    check.call("Mallory list_members on a non-member list → 403", r["mallory_list_members"] == 403)
    check.call("Mallory replay of the member's used code → 403",  r["mallory_replay_used_code"] == 403)
    check.call("Mallory garbage invite code → 403",               r["mallory_garbage_code"] == 403)
    check.call("POSITIVE CONTROL: genuine member sees the list",  r["member_sees_list"])
    check.call("POSITIVE CONTROL: genuine member reads todos → 200", r["member_reads_todos"] == 200)
    check.call("remove_member → 200",                            r["remove_member_status"] == 200)
    check.call("after removal, member's next read → 403 (access gone)", r["member_after_removal"] == 403)

    # ── Assertion 8a: the catalog PUBLISHES the reach of tudu's four queries ──
    #
    # K-949 / ADR-0028. Collaboration is a legitimate authorization model and
    # the spec no longer forbids it — what it requires is that the model be a
    # DECLARED property of the verb rather than something a reader has to infer
    # from a join. `consented` rather than `published` is the stronger of the
    # two sharing claims and is the true one here: what admits another
    # account's row is a `memberships` row this operator can produce, minted by
    # redeeming an invite a human created.
    want_reach = { "my_lists" => "consented", "list_todos" => "consented",
                   "list_members" => "consented", "whoami" => "principal" }
    got_reach  = (r["reach_by_verb"] || {}).slice(*want_reach.keys)
    check.call("Assertion 8a: the catalog declares #{want_reach.inspect} (got #{got_reach.inspect})",
               got_reach == want_reach)

    # ── Assertion 8b: nothing claiming `principal` returns the owner's list ──
    #
    # NON-VACUITY IS ASSERTED, NOT ASSUMED: an empty probe set would pass this
    # while checking nothing, which is how a green isolation report gets
    # manufactured. whoami is a principal-reach no-argument query, so the set is
    # never legitimately empty.
    probe = r["principal_probe"] || []
    check.call("Assertion 8b: the principal-reach probe set is NON-EMPTY (#{probe.map(&:first).inspect})",
               !probe.empty?)
    leaked = probe.select { |(_name, prc, body)| prc == 200 && body.to_s.include?(r["list_id"].to_s) }
    check.call("Assertion 8b: no principal-reach verb returned the owner's list to the member " \
               "(#{probe.length} probed#{leaked.empty? ? "" : "; LEAKED: #{leaked.map(&:first).join(", ")}"})",
               !probe.empty? && leaked.empty?)

    # The principal is not an input, asserted in two halves.
    #
    # (a) The forged account_id is REFUSED by the published contract: create_list
    #     declares `additionalProperties: false` and only `title`, and since 0.4
    #     input_schema is validated on every call, so the wire answers a typed
    #     400 naming the parameter instead of accepting and ignoring it.
    forged_rc, forged_code, forged_detail = r["forged_refusal"] || []
    check.call("forged account_id → 400 bad_request naming account_id (refused by input_schema before the handler runs)",
               forged_rc == 400 && forged_code == "bad_request" && forged_detail.to_s.include?("account_id"))
    # (b) …and ownership comes from the TOKEN, which the refusal alone does not
    #     prove: Mallory's legitimate list is hers in the DB.
    probe_owner = `psql -X -d #{db} -tAc "SELECT account_id FROM lists WHERE id = '#{r["owner_probe_list_id"]}'" 2>&1`.strip
    check.call("ownership taken from the identity: DB lists.account_id == Mallory (#{r["mallory_user_id"]})",
               probe_owner == r["mallory_user_id"])

    if failures.empty?
      puts "\n  All membership isolation assertions passed — non-members are walled out."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end

namespace :demo do
  desc <<~DESC
    Adversarial regression battery — attacks tudu's live surface.

    Asserts each attack is BLOCKED (0 BREACH): CrossTenantRead, ForgedUserId
    (the forged account_id is now REFUSED 400, not accepted-and-ignored),
    MalformedUuidArg (400), MissingAuth (401), GarbageToken (401), UnknownQuery
    (404), UnknownAction (404), RetiredWire (the deleted 0.3 /kiosk/query and
    /kiosk/run are an ordinary 404), MethodMismatch (a GET at an action's path
    is 405 + Allow, never a silent 404), plus tudu beats — InviteCodeReplay
    (403), RevokedMemberAccess (403), RevokedAgentKey (404),
    PreLinkTokenAfterLink (401).
  DESC
  task redteam: :setup do
    port = ENV.fetch("PORT", "3007")
    log  = "/tmp/kiosk-tudu-redteam.log"
    holder_id       = "00000000-0000-0000-0000-000000000001"
    holder_email    = "alice@example.com"
    holder_password = "tudu-demo-password"

    puts "\n── Starting tudu (redteam battery) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    at_exit { tudu_stop(server_pid) }

    suite = File.expand_path("../../script/redteam_suite.rb", __dir__)
    puts "\n── Running script/redteam_suite.rb ──"
    ok = system({ "SERVER_URL" => server_url, "KIOSK_ISSUER" => server_url,
                  "HOLDER_ID" => holder_id, "HOLDER_EMAIL" => holder_email, "HOLDER_PASSWORD" => holder_password },
                "bundle", "exec", "ruby", suite)
    if ok
      puts "\n  redteam: all scenarios BLOCKED. Exit 0."
    else
      puts "\n  redteam: BREACH DETECTED or error — see output above."
      exit 1
    end
  end
end

namespace :demo do
  desc <<~DESC
    Self-discovery + NOT-ONLY-COMMERCE proof.

    Asserts the schema catalog (queries/actions + non-empty descriptions,
    including invite/accept_invite) AND that the advertised capabilities do NOT
    include `pay`, agents.json carries no payments block, and agents.txt carries
    no `Protocols: ap2` / `Payments:` directives.

    Also asserts the discovery SIGNAL over HTTP: the `<link rel="kiosk">` tag and
    the `Link: <…>; rel="kiosk"` header both name a VERSIONED cut — never the
    mutable `skill.md` alias — and both agree with the `skill` pin in
    /.well-known/kiosk.json (K-927, protocol.md §4.5).
  DESC
  task schema: :setup do
    port = ENV.fetch("PORT", "3007")
    log  = "/tmp/kiosk-tudu-schema.log"

    puts "\n── Starting tudu (schema proof) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    at_exit { tudu_stop(server_pid) }

    flow = File.expand_path("../../script/schema_flow.rb", __dir__)
    puts "\n── Running script/schema_flow.rb ──"
    r = tudu_run_flow(flow, server_url)

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
    %w[/ /shared].each do |page|
      res = Net::HTTP.get_response(URI("#{server_url}#{page}"))
      advertised[%(<link rel="kiosk"> tag)] ||=
        res.body.to_s[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
      advertised[%(Link: <…>; rel="kiosk" header)] ||=
        res["Link"].to_s[/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
    end

    advertised.each do |what, url|
      if url.nil? || url.empty?
        failures << "#{what}: absent from #{%w[/ /shared].join(", ")} — §4.5's signal is not served"
        puts "  ✗  #{what} absent from #{%w[/ /shared].join(", ")}"
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
    check = ->(label, ok) { ok ? puts("  ✓  #{label}") : (failures << label; puts("  ✗  #{label}")) }
    puts "\n── Schema + discovery assertions ──"

    query_specs  = r["schema_queries"] || []
    action_specs = r["schema_actions"] || []
    queries = query_specs.map  { |q| q["name"] }
    actions = action_specs.map { |a| a["name"] }
    capabilities = r["discovery_capabilities"] || []

    # The schema call carried NO Authorization header (T-094): this status IS
    # the public-access proof. And the MODULE set is asserted at its one
    # remaining home — `schema.verbs` was a byte-identical copy until T-095.
    check.call("GET /kiosk/schema answered 200 with NO Authorization header", r["schema_status"] == 200)
    %w[schema queries actions].each { |v| check.call("capabilities includes #{v}", capabilities.include?(v)) }
    %w[whoami my_lists list_todos list_members].each { |q| check.call("schema.queries includes #{q}", queries.include?(q)) }
    %w[create_list add_todo complete_todo invite accept_invite remove_member].each { |a| check.call("schema.actions includes #{a}", actions.include?(a)) }

    (query_specs + action_specs).each do |spec|
      desc = spec["description"]
      check.call("schema entry #{spec['name']} carries a description", desc.is_a?(String) && !desc.strip.empty?)
    end

    # T-042 / K-452: the primary read query (my_lists) and primary action
    # (create_list) advertise the machine-readable descriptor extensions.
    {
      query_specs  => %w[my_lists],
      action_specs => %w[create_list],
    }.each do |list, names|
      names.each do |dname|
        entry = list.find { |e| e["name"] == dname } || {}
        %w[input_schema example_params example_row].each do |ext|
          check.call("#{dname} advertises #{ext}", entry.key?(ext) && !entry[ext].nil?)
        end
      end
    end

    # ── NOT-ONLY-COMMERCE: pay absent from the ADVERTISED capability set ──
    check.call("discovery capabilities do NOT include `pay` (#{capabilities.inspect})", !capabilities.include?("pay"))
    %w[schema queries actions].each { |c| check.call("discovery capabilities include #{c}", capabilities.include?(c)) }
    check.call("agents.json carries NO payments block",                 !r["agents_json_has_payments"])
    check.call("agents.txt carries NO `Protocols: ap2` / `Payments:`",  !r["agents_txt_has_ap2"] && !r["agents_txt_has_payments"])

    if failures.empty?
      puts "\n  All schema + discovery assertions passed (pay ABSENT — not-only-commerce)."
    else
      puts "\n  FAILED assertions:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end

# Shared teardown.
def tudu_stop(pid)
  Process.kill("TERM", pid); Process.wait(pid)
rescue Errno::ESRCH, Errno::ECHILD
  nil
ensure
  puts "  Server stopped."
end
