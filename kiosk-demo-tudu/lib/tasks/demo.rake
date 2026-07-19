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
  abort "Server did not become ready — see #{log}" unless ready
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
    # secret_key_base exists (Devise sessions need it) — idempotent.
    sh "test -f config/credentials.yml.enc && test -f config/master.key || " \
       "EDITOR=true bundle exec rails credentials:edit >/dev/null 2>&1 || true"
    sh "bundle exec rails db:drop db:create db:migrate db:seed"
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
    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-tudu-collab.log"
    puts "\n── Starting tudu (collaboration happy path) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    at_exit { tudu_stop(server_pid) }

    flow = File.expand_path("../../collab_flow.rb", __dir__)
    puts "\n── Running collab_flow.rb ──"
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
    Alice ends with >=2 non-revoked agents.
  DESC
  task link: :setup do
    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-tudu-link.log"
    db   = "kiosk_tudu_development"
    holder_id       = "00000000-0000-0000-0000-000000000001"
    holder_email    = "alice@example.com"
    holder_password = "tudu-demo-password"

    puts "\n── Starting tudu (W5 rebind walkthrough) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    failures = []
    begin
      flow = File.expand_path("../../link_flow.rb", __dir__)
      puts "\n── Running link_flow.rb ──"
      r = tudu_run_flow(flow, server_url,
                        "HOLDER_ID" => holder_id, "HOLDER_EMAIL" => holder_email, "HOLDER_PASSWORD" => holder_password)

      check = ->(label, ok) { ok ? puts("  OK  #{label}") : (failures << label; puts("  x  #{label}")) }
      puts "\n── W5 rebind assertions ──"
      check.call("human signed in via the real Devise form",        r["human_signed_in"] == true)
      check.call("link code minted (session channel) → 201",        r["link_mint"] == 201)
      check.call("claim rebound the key to Alice (same agent_id)",   r["claim_status"] == 201 && r["claim_rebound_to_holder"] && r["claim_same_agent_id"])
      check.call("pre-link token's principal owns nothing (migrated away)", r["prelink_status"] == 200 && r["prelink_list_empty"])
      check.call("re-login mints a token whose sub is Alice",        r["relogin_sub_is_holder"])
      check.call("re-logged-in agent sees 'Hike' as owner under Alice", r["agent_sees_migrated_list"])
      check.call("Alice's browser session sees 'Hike'",             r["human_sees_migrated_list"])
      check.call("a SECOND assistant links to Alice (multi-agent)", r["second_bound_to_holder"])

      # DB ground truth: the list was migrated to Alice; Alice has >=2 live agents.
      list_owner = `psql -X -d #{db} -tAc "SELECT account_id FROM lists WHERE id = '#{r["list_id"]}'" 2>&1`.strip
      check.call("DB lists.account_id for 'Hike' == Alice (#{holder_id}) — assistant_claimed migrated it", list_owner == holder_id)
      agent_count = `psql -X -d #{db} -tAc "SELECT count(*) FROM kiosk.agents WHERE user_id = '#{holder_id}' AND revoked_at IS NULL" 2>&1`.strip
      check.call("DB: Alice has >=2 non-revoked agents (multi-agent identity)", agent_count.to_i >= 2)
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
      • forged account_id on Mallory's create_list ignored (DB truth via psql)
      • a used/garbage invite code → 403
      • POSITIVE CONTROL: the genuine member DOES see + read the list
      • after remove_member, the member's next read → 403 (access gone)
  DESC
  task isolation: :setup do
    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-tudu-isolation.log"
    db   = "kiosk_tudu_development"

    puts "\n── Starting tudu (membership isolation test) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    at_exit { tudu_stop(server_pid) }

    flow = File.expand_path("../../isolation_flow.rb", __dir__)
    puts "\n── Running isolation_flow.rb ──"
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

    # Forged account_id ground truth: the created list belongs to Mallory, not owner.
    forged_owner = `psql -X -d #{db} -tAc "SELECT account_id FROM lists WHERE id = '#{r["forged_list_id"]}'" 2>&1`.strip
    check.call("forged account_id ignored: DB lists.account_id == Mallory (#{r["mallory_user_id"]})", forged_owner == r["mallory_user_id"])

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

    Asserts each attack is BLOCKED (0 BREACH): CrossTenantRead, ForgedUserId,
    MissingAuth (401), GarbageToken (401), UnknownQuery (404), UnknownAction
    (404), plus tudu beats — InviteCodeReplay (403), RevokedMemberAccess (403),
    RevokedAgentKey (404), PreLinkTokenAfterLink (403).
  DESC
  task redteam: :setup do
    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-tudu-redteam.log"
    holder_id       = "00000000-0000-0000-0000-000000000001"
    holder_email    = "alice@example.com"
    holder_password = "tudu-demo-password"

    puts "\n── Starting tudu (redteam battery) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    at_exit { tudu_stop(server_pid) }

    suite = File.expand_path("../../redteam_suite.rb", __dir__)
    puts "\n── Running redteam_suite.rb ──"
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
  DESC
  task schema: :setup do
    port = ENV.fetch("PORT", "3001")
    log  = "/tmp/kiosk-tudu-schema.log"

    puts "\n── Starting tudu (schema proof) ──"
    server_pid, server_url = tudu_boot_server(log: log, port: port)
    at_exit { tudu_stop(server_pid) }

    flow = File.expand_path("../../schema_flow.rb", __dir__)
    puts "\n── Running schema_flow.rb ──"
    r = tudu_run_flow(flow, server_url)

    failures = []
    check = ->(label, ok) { ok ? puts("  ✓  #{label}") : (failures << label; puts("  ✗  #{label}")) }
    puts "\n── Schema + discovery assertions ──"

    verbs        = r["schema_verbs"]   || []
    query_specs  = r["schema_queries"] || []
    action_specs = r["schema_actions"] || []
    queries = query_specs.map  { |q| q["name"] }
    actions = action_specs.map { |a| a["name"] }
    capabilities = r["discovery_capabilities"] || []

    %w[query run schema].each { |v| check.call("schema.verbs includes #{v}", verbs.include?(v)) }
    %w[whoami my_lists list_todos list_members].each { |q| check.call("schema.queries includes #{q}", queries.include?(q)) }
    %w[create_list add_todo complete_todo invite accept_invite remove_member].each { |a| check.call("schema.actions includes #{a}", actions.include?(a)) }

    (query_specs + action_specs).each do |spec|
      desc = spec["description"]
      check.call("schema entry #{spec['name']} carries a description", desc.is_a?(String) && !desc.strip.empty?)
    end

    # ── NOT-ONLY-COMMERCE: pay absent from the ADVERTISED capability set ──
    check.call("discovery capabilities do NOT include `pay` (#{capabilities.inspect})", !capabilities.include?("pay"))
    %w[schema query run].each { |c| check.call("discovery capabilities include #{c}", capabilities.include?(c)) }
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
