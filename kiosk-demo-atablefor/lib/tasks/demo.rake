# frozen_string_literal: true

# Kiosk demo orchestration (atablefor — restaurant table-booking). Tasks:
#
#   rake demo:setup        idempotent db:drop / create / schema:load / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase, tears down
#   rake demo:book         boots the server, runs script/book_flow.rb (no-human table booking),
#                          asserts the confirmed booking, tears down
#   rake demo:pow          boots with KIOSK_POW_DEMO=1, runs script/pow_flow.rb (402→solve→200)
#                          at TOY params (n=96 k=5) unless KIOSK_POW_DIFFICULTY=high
#   rake demo:reputation   anti-scalping PoW demo (cost drops as bookings accrue)
#   rake demo:backoff      count-based PoW backoff (solve once → next N calls free →
#                          re-challenge; sets KIOSK_POW_BACKOFF_DEMO=3 — the value
#                          is the free-call count)
#   rake demo:binding      account-binding: a diner links their assistant, whose
#                          booking then ties to the diner's account
#   rake demo:isolation    adversarial cross-tenant isolation test
#   rake demo:schema       self-discovery proof — verifies the schema verb + pay-absent
#   rake demo:redteam      adversarial regression battery
#   rake demo              setup + book (the full end-to-end proof)
#
# atablefor takes NO payments (a reservation needs none), so there is no
# demo:rls / demo:order / pay path — the RLS *showcase* lives in getgrocery.
# The walkthrough lives in bin/demo (POSIX shell) so it's debuggable without
# going through Rake.

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
def atablefor_run_flow(flow_rb, env_str = "", env: {}, runner: "ruby")
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

namespace :demo do
  desc "Create + load schema + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    # Path C: schema_format = :sql, so db:schema:load loads structure.sql
    # directly. Use db:schema:load instead of db:migrate so the canonical
    # structure.sql is the source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc "Boot the server and run the curl demo walkthrough."
  task walkthrough: :setup do
    exec File.expand_path("../../bin/demo", __dir__)
  end

  desc "Boot the server, run the no-human script/book_flow.rb end-to-end, assert the booking."
  task :book do
    require "resolv"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-demo.log"

    # ── host resolution ────────────────────────────────────────────────
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
      addr = Resolv.getaddress("atablefor.demo.kiosk.tech") rescue ""
      if addr == "127.0.0.1"
        "atablefor.demo.kiosk.tech"
      else
        puts "  add to /etc/hosts:  127.0.0.1 atablefor.demo.kiosk.tech"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor on #{server_url} ──"

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

    # ── run script/book_flow.rb ───────────────────────────────────────────────
    flow_rb = File.expand_path("../../script/book_flow.rb", __dir__)
    puts "\n── Running script/book_flow.rb ──"
    result = atablefor_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}")

    # ── assertions: HTTP + JSON ────────────────────────────────────────
    puts "\n── Assertions ──"
    failures = []

    booking     = result["booking"]     || {}
    my_bookings = result["my_bookings"] || []

    booking_id = booking["booking_id"]
    if booking_id && !booking_id.empty?
      puts "  ✓  booking.booking_id present (#{booking_id})"
    else
      failures << "booking.booking_id missing"
      puts "  ✗  booking.booking_id missing"
    end

    if booking["status"] == "confirmed"
      puts "  ✓  booking.status == confirmed"
    else
      failures << "booking.status expected 'confirmed', got #{booking["status"].inspect}"
      puts "  ✗  booking.status — got #{booking["status"].inspect}"
    end

    if booking["party_size"] == 2
      puts "  ✓  booking.party_size == 2 (a table for two)"
    else
      failures << "booking.party_size expected 2, got #{booking["party_size"].inspect}"
      puts "  ✗  booking.party_size — got #{booking["party_size"].inspect}"
    end

    # my_bookings must show exactly the one confirmed booking just made.
    if my_bookings.size == 1 && my_bookings.first["booking_id"] == booking_id && my_bookings.first["status"] == "confirmed"
      puts "  ✓  my_bookings shows the confirmed booking (id=#{booking_id})"
    else
      failures << "my_bookings expected [{id:#{booking_id}, status:confirmed}], got #{my_bookings.inspect}"
      puts "  ✗  my_bookings — got #{my_bookings.inspect}"
    end

    # ── assertions: psql ground truth ──────────────────────────────────
    # Assert the SPECIFIC booking just made (by id), not a DB-wide COUNT. The
    # reason this comment used to give — "the seeds place a couple of existing
    # reservations on the board" — stopped being true: db/seeds.rb now says the
    # public board is deliberately EMPTY at rest (K-712f). The rule survives its
    # old reason. A DB-wide count cannot tell the row THIS run created from one
    # a previous run left behind, or from a future seed change; the id can.
    db = "kiosk_atablefor_development"

    this_booking = `psql -X -d #{db} -tAc "SELECT status FROM bookings WHERE id = '#{booking_id}'" 2>&1`.strip
    if this_booking == "confirmed"
      puts "  ✓  the new booking is confirmed in the DB (id=#{booking_id})"
    else
      failures << "new booking #{booking_id} status expected 'confirmed', got #{this_booking.inspect}"
      puts "  ✗  new booking status — got #{this_booking.inspect}"
    end

    # The booking must pin a physical table + a concrete seating instant (the
    # finite-contention model: a confirmed row on (table, seating_at) holds it).
    this_seating = `psql -X -d #{db} -tAc "SELECT restaurant_table_id IS NOT NULL AND seating_at IS NOT NULL FROM bookings WHERE id = '#{booking_id}'" 2>&1`.strip
    if this_seating == "t"
      puts "  ✓  the booking pins a table + seating instant (restaurant_table_id + seating_at set)"
    else
      failures << "the new booking must have restaurant_table_id + seating_at set, got #{this_seating.inspect}"
      puts "  ✗  the new booking's table/seating — got #{this_seating.inspect}"
    end

    if failures.empty?
      puts "\n  All assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end

  desc <<~DESC
    Query-toll PoW demo (KIOSK_POW_DEMO=1): 402 → solve.py → 200, wrong nonce → 403.

    RUNS AT TOY PARAMETERS BY DEFAULT — Equihash n=96 k=5, `KIOSK_POW_DIFFICULTY`'s
    `low`. That is a sub-second solve, which is what keeps this task runnable in
    CI and on a laptop, and it is NOT the toll a real operator charges.

    To exercise the SHIPPED parameters — n=168 k=7, kiosk-pow-equihash's own
    default and what the hosted atablefor serves:

      KIOSK_POW_DIFFICULTY=high bundle exec rake demo:pow

    Budget ~10 s and ~1.3 GiB of RSS PER PROOF from the reference solver
    (bench/README.md, measured on one M-series laptop core) — that gibibyte is
    that solver's sorted-nonce table, not a floor these params impose on every
    solver. The flow pays that toll MORE THAN ONCE: registration is tolled too,
    and script/equihash_register.rb solves it transparently for each identity
    the flow mints. So the run COUNTS every solve and prints the total beside
    its verdict instead of promising a number typed here — this sentence used
    to say "four", and the run it describes solves three (K-1221). The task
    prints the (n, k) it actually ran at, at boot and again beside its verdict,
    so a recording can never leave a viewer guessing which toll they watched
    being paid (T-110).

    Requires python3 + numpy.
  DESC
  task :pow do
    # Requirement: python3 with numpy (the equihash solver is vectorised).
    # Install with: pip install numpy
    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    unless python_ok
      abort "numpy not found. Install with: pip install numpy\n" \
            "Then re-run: bundle exec rake demo:pow"
    end

    # ── The toll this run pays, DERIVED and then PRINTED (T-110) ──────────────
    #
    # `demo:pow` is the only end-to-end exercise of the proof-of-work plane in
    # this repo, and until now it pinned nothing about the parameters: it set
    # `KIOSK_POW_DEMO=1` and nothing else, so it always ran at `PowDifficulty`'s
    # `low` default while the shipped kiosk-pow-equihash default — and the
    # hosted deploy — are n=168 k=7. Nothing anywhere demonstrated end to end
    # that an assistant can pay the toll a real operator charges, and a reader
    # watching this task had no way to tell which of the two they were seeing.
    #
    # Both halves are fixed here and neither costs a gate: the ambient
    # `KIOSK_POW_DIFFICULTY` is now FORWARDED to the server this task spawns
    # (it was being dropped, so setting it did nothing), and the pair is read
    # off {PowDifficulty} — the same module the initializer reads — rather than
    # typed here, then printed at boot and beside the verdict. The default is
    # unchanged, so CI and a bare `rake demo:pow` cost exactly what they did.
    require File.expand_path("../../app/services/pow_difficulty.rb", __dir__)
    pow_level  = PowDifficulty.level
    pow_params = PowDifficulty.params

    require "resolv"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-pow-demo.log"

    host = begin
      addr = Resolv.getaddress("atablefor.demo.kiosk.tech") rescue ""
      addr == "127.0.0.1" ? "atablefor.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (PoW demo) on #{server_url} ──"
    puts "  toll: Equihash n=#{pow_params[:n]} k=#{pow_params[:k]} " \
         "(KIOSK_POW_DIFFICULTY=#{pow_level}#{pow_level == PowDifficulty::DEFAULT ? ", the default" : ""})"
    if PowDifficulty.high?
      puts "  These are the SHIPPED parameters — the toll a real operator charges. " \
           "Expect ~10 s and ~1.3 GiB per proof from the reference solver — that " \
           "GiB is its table, not a floor these params impose on every solver. " \
           "The flow solves MORE than one proof — registration is tolled too — " \
           "and the count it actually paid is printed beside the verdict (K-1221)."
    else
      puts "  TOY parameters. The shipped kiosk-pow-equihash default is n=168 k=7 — " \
           "re-run with KIOSK_POW_DIFFICULTY=high to pay the real toll."
    end

    # ONE owner for the toy counter's location (K-711, K-785). The server and
    # the driver are two processes that never meet; this task spawns both, so
    # it is the only place the path can be stated once. Wiped HERE — the beat
    # asserts exact counts, and the initializer must not truncate a store at
    # boot in a file an adopter copies.
    bad_proof_db = File.expand_path("../../tmp/bad-proof.sqlite3", __dir__)
    require "fileutils"
    require "shellwords"
    FileUtils.mkdir_p(File.dirname(bad_proof_db))
    FileUtils.rm_f(bad_proof_db)

    env_vars = {
      "KIOSK_ISSUER"           => kiosk_issuer,
      "KIOSK_POW_DEMO"         => "1",
      "KIOSK_BAD_PROOF_DB"     => bad_proof_db,
      # Forwarded, not defaulted: `spawn` with an env Hash still inherits the
      # parent's environment, but naming it here is what makes the server's
      # level and the level printed above the SAME read (T-110).
      "KIOSK_POW_DIFFICULTY"   => pow_level,
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

    # Run script/pow_flow.rb.
    flow_rb = File.expand_path("../../script/pow_flow.rb", __dir__)
    puts "\n── Running script/pow_flow.rb ──"
    env = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} " \
          "KIOSK_BAD_PROOF_DB=#{bad_proof_db.shellescape}"
    result = atablefor_run_flow(flow_rb, env)

    # ── Assertions ──
    puts "\n── PoW assertions (Equihash n=#{pow_params[:n]} k=#{pow_params[:k]}, " \
         "KIOSK_POW_DIFFICULTY=#{pow_level}) ──"
    failures = []

    # WHICH TOLL WAS ACTUALLY PAID (T-110), asserted off the WIRE rather than
    # printed off this task's own read. A banner naming the parameters is a
    # claim; the challenge the server issued is evidence, and it is what follows
    # an operator override or a policy this task cannot see. Without this the
    # opt-in path could silently keep running at `low` and the recording would
    # still say `high`.
    served_params = result["challenge_params"].is_a?(Hash) ? result["challenge_params"] : {}
    if served_params["n"].to_i == pow_params[:n] && served_params["k"].to_i == pow_params[:k]
      puts "  ✓  toll served at the level asked for: n=#{served_params["n"]} k=#{served_params["k"]}" \
           "#{PowDifficulty.high? ? " — the SHIPPED parameters" : " (toy; KIOSK_POW_DIFFICULTY=high for n=168 k=7)"}"
    else
      failures << "the wire served n=#{served_params["n"].inspect} k=#{served_params["k"].inspect}, " \
                  "but KIOSK_POW_DIFFICULTY=#{pow_level} asks for n=#{pow_params[:n]} k=#{pow_params[:k]}"
      puts "  ✗  toll parameters — served #{served_params.inspect}, wanted #{pow_params.inspect}"
    end

    # HOW MANY PROOFS THIS RUN ACTUALLY PAID FOR (K-1221), counted by the driver
    # where the solver runs rather than typed here. This task's prose used to
    # promise "four" while the driver reported one: it counted only the tolled
    # query's challenges and not the registration proof `equihash_register`
    # solves transparently for each identity the flow mints. It is the number a
    # viewer multiplies by the per-proof budget to size a recording, so it is
    # ASSERTED — a printed total that does not equal its own two parts is a
    # counter that has come loose from what it counts.
    solved     = result["proofs_solved"].to_i
    reg_proofs = result["registration_proofs_solved"].to_i
    qry_proofs = result["tolled_query_proofs"].to_i
    if solved.positive? && solved == reg_proofs + qry_proofs
      puts "  ✓  proofs solved this run: #{solved} (#{reg_proofs} at registration, " \
           "#{qry_proofs} at the tolled query) — multiply by the per-proof budget above"
    else
      failures << "proofs_solved=#{solved} does not add up from " \
                  "registration_proofs_solved=#{reg_proofs} + tolled_query_proofs=#{qry_proofs}"
      puts "  ✗  proof count does not add up: #{result.slice('proofs_solved', 'registration_proofs_solved', 'tolled_query_proofs').inspect}"
    end

    if result["http_challenge"] == 402
      puts "  ✓  query challenged: HTTP 402 (pow_required)"
    else
      failures << "expected http_challenge=402, got #{result["http_challenge"].inspect}"
      puts "  ✗  expected HTTP 402, got #{result["http_challenge"].inspect}"
    end

    if result["served"] == true && result["http_served_after_solve"] == 200
      puts "  ✓  served after real solve.py: HTTP 200, #{result["availability_rows"]} open slots"
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

    # PER-IDENTITY (K-498): a second, innocent identity registered by the flow
    # must be untouched by the first identity's wrong nonce — one bad client
    # must not raise anyone else's count.
    obpc = result["other_bad_proof_count"].to_i
    if obpc.zero?
      puts "  ✓  per-identity counter: innocent identity's bad_proof_count=0"
    else
      failures << "expected other_bad_proof_count=0 (per-identity, K-498), got #{obpc}"
      puts "  ✗  other_bad_proof_count=#{obpc} (expected 0 — counter not per-identity)"
    end

    if failures.empty?
      puts "\n  All PoW assertions passed at Equihash n=#{pow_params[:n]} k=#{pow_params[:k]} " \
           "(KIOSK_POW_DIFFICULTY=#{pow_level})."
      unless PowDifficulty.high?
        puts "  These are TOY parameters. `KIOSK_POW_DIFFICULTY=high bundle exec rake demo:pow` " \
             "runs the same flow at the shipped n=168 k=7."
      end
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end

  # ── demo:reputation ────────────────────────────────────────────────────────
  desc <<~DESC
    Anti-scalping reputation PoW demo (trust earned by booking).

    Boots the server with KIOSK_POW_REPUTATION_DEMO=1, runs script/reputation_flow.rb:
      0 confirmed bookings → 402 with 2 equihash challenges (unproven)
      1 confirmed booking  → 402 with 1 challenge (a booking earns relief)
      2 confirmed bookings → 200 served directly, NO challenge (proven — free pass)

    The anti-reservation-scalping mechanic: a fresh / low-reputation agent pays
    escalating PoW to probe prime-time availability; a scalper renting fresh
    identities pays and pays, while a returning diner earns relief.

    Asserts:
      • proofs_unproven > proofs_after_1_booking  (cost dropped with a booking)
      • served_after_2_bookings == true           (query is free once proven)
      • challenge_after_2 == nil                   (no PoW issued to a proven principal)

    Policy: Kiosk::Reputation::Policies::RateAndReputation
      proven_purchases_threshold: 2, base_count: 1, unproven_count_bonus: 1
    Factors: real DB lookup — COUNT(*) FROM bookings WHERE user_id = <principal>
             AND status = 'confirmed' (mapped into the policy's proven-count factor)

    Requirements:
      python3 with numpy: pip install numpy
  DESC
  task :reputation do
    # Requirement: python3 with numpy (the equihash solver is vectorised).
    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    unless python_ok
      abort "numpy not found. Install with: pip install numpy\n" \
            "Then re-run: bundle exec rake demo:reputation"
    end

    require "resolv"

    port = ENV.fetch("PORT", "3104")  # distinct from the dev port (3002, where demo:pow runs) AND outside the 3001-3008 band the sibling demos' dev ports occupy (K-649)
    log  = "/tmp/kiosk-atablefor-reputation-demo.log"

    host = begin
      addr = Resolv.getaddress("atablefor.demo.kiosk.tech") rescue ""
      addr == "127.0.0.1" ? "atablefor.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (anti-scalping reputation PoW demo) on #{server_url} ──"
    puts "   Policy: RateAndReputation (proven_purchases_threshold=2, base_count=1, unproven_count_bonus=1)"
    puts "   Factors: real DB lookup — bookings WHERE user_id = <principal> AND status = 'confirmed'"
    puts "   Expected curve (by PROOF COUNT, N×PoW): 2 proofs (0 bookings) → 1 proof (1 booking) → free pass (2 bookings)"

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

    # Run script/reputation_flow.rb.
    flow_rb = File.expand_path("../../script/reputation_flow.rb", __dir__)
    puts "\n── Running script/reputation_flow.rb ──"
    result = atablefor_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}")

    # ── Assertions ──
    puts "\n── Reputation PoW assertions ──"
    failures = []

    n_unproven = result["proofs_unproven"]
    n_after_1  = result["proofs_after_1_booking"]
    served_2   = result["served_after_2_bookings"]
    n_after_2  = result["challenge_after_2"]

    puts "  Proof-count curve: #{n_unproven} (0 bookings) → #{n_after_1} (1 booking) → #{n_after_2.inspect} (2 bookings)"

    if n_unproven.to_i > n_after_1.to_i
      puts "  ✓  proof count dropped: #{n_unproven} → #{n_after_1} (a booking earns relief)"
    else
      failures << "expected proofs_unproven(#{n_unproven}) > proofs_after_1_booking(#{n_after_1}) — cost must drop after first booking"
      puts "  ✗  proof count did NOT drop after 1st booking: #{n_unproven} → #{n_after_1}"
    end

    if served_2 == true && n_after_2.nil?
      puts "  ✓  free pass after 2 bookings: query served without any challenge (proven principal)"
    else
      failures << "expected served_after_2_bookings=true + challenge_after_2=nil; got served=#{served_2.inspect}, challenge=#{n_after_2.inspect}"
      puts "  ✗  NOT served without challenge after 2 bookings (served=#{served_2.inspect}, n_after_2=#{n_after_2.inspect})"
    end

    if failures.empty?
      puts "\n  All reputation assertions PASSED."
      puts "  Anti-scalping: PoW proof-count curve demonstrated end-to-end (cost drops as a real booking history accrues)."
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:reputation ────────────────────────────────────────────────────

  # ── demo:backoff ───────────────────────────────────────────────────────────
  desc <<~DESC
    COUNT-BASED PoW backoff demo — "solve once, next N calls free" (POW-RECENCY-GRACE).

    Boots the server with KIOSK_POW_BACKOFF_DEMO=3 (the value is the free-call
    count, not a boolean), runs script/backoff_flow.rb:
      fresh identity queries → 402 (pow_required, no grant yet)
      solves via the bundled solver, resubmits → 200 (proof verified → grant set to 3)
      the NEXT 3 requests are served WITHOUT a challenge (200 — the grant consumed)
      the 4th request is challenged again (402 — the grant is exhausted)

    A COUNT (not a time window) is deliberate: a window would let a bot flood
    thousands of requests inside it; a count caps exactly how many free calls one
    ~9 s solve buys, then the toll returns.

    Asserts:
      • http_first_challenge == 402       (a fresh identity is tolled)
      • http_served_after_solve == 200    (a solve verifies and sets the grant)
      • free_call_statuses == [200,200,200] (the 3 granted follow-ups are free)
      • http_after_grant == 402           (the 4th is re-challenged)

    Policy: Kiosk::Reputation::Policies::Backoff.new(count: 3, base: {equihash, count: 1})
    Store:  the in-process BackoffStore — authoritative per worker; a multi-worker
            deploy needs a shared store (Redis/DB) or the grant is only per-worker.

    Requirements:
      python3 with numpy: pip install numpy
  DESC
  task :backoff do
    # Requirement: python3 with numpy (the equihash solver is vectorised).
    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    unless python_ok
      abort "numpy not found. Install with: pip install numpy\n" \
            "Then re-run: bundle exec rake demo:backoff"
    end

    require "resolv"

    port = ENV.fetch("PORT", "3106")  # distinct port (pow=3002, reputation=3104), outside the sibling demos' 3001-3008 dev-port band (K-649)
    log  = "/tmp/kiosk-atablefor-backoff-demo.log"

    host = begin
      addr = Resolv.getaddress("atablefor.demo.kiosk.tech") rescue ""
      addr == "127.0.0.1" ? "atablefor.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (count-based PoW backoff demo) on #{server_url} ──"
    puts "   Policy: Backoff (count=3) — one solve buys the next 3 calls free, then re-challenge"

    env_vars = {
      "KIOSK_ISSUER"            => kiosk_issuer,
      "KIOSK_POW_BACKOFF_DEMO"  => "3", # the value is the free-call count; the flow asserts exactly 3
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
    puts "  Server up at #{server_url} (backoff PoW active)"

    flow_rb = File.expand_path("../../script/backoff_flow.rb", __dir__)
    puts "\n── Running script/backoff_flow.rb ──"
    result = atablefor_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}")

    # ── Assertions ──
    puts "\n── Backoff PoW assertions ──"
    failures = []

    if result["http_first_challenge"] == 402
      puts "  ✓  fresh identity tolled: HTTP 402 (pow_required, no grant yet)"
    else
      failures << "expected http_first_challenge=402, got #{result["http_first_challenge"].inspect}"
      puts "  ✗  first query not challenged: #{result["http_first_challenge"].inspect}"
    end

    if result["http_served_after_solve"] == 200
      puts "  ✓  served after real solve.py: HTTP 200 (proof verified → grant set to #{result["grant_count"]})"
    else
      failures << "expected http_served_after_solve=200, got #{result["http_served_after_solve"].inspect}"
      puts "  ✗  not served after solve: #{result["http_served_after_solve"].inspect}"
    end

    free = result["free_call_statuses"] || []
    if free.size == result["grant_count"] && free.all? { |s| s == 200 }
      puts "  ✓  the next #{result["grant_count"]} calls served WITHOUT a challenge (#{free.inspect}) — grant consumed"
    else
      failures << "expected #{result["grant_count"]} free 200s after the solve, got #{free.inspect}"
      puts "  ✗  granted follow-ups not all free: #{free.inspect}"
    end

    if result["http_after_grant"] == 402
      puts "  ✓  grant exhausted → the next call is re-challenged: HTTP 402"
    else
      failures << "expected http_after_grant=402, got #{result["http_after_grant"].inspect}"
      puts "  ✗  grant did not expire — 4th call returned #{result["http_after_grant"].inspect}"
    end

    if failures.empty?
      puts "\n  All backoff assertions PASSED."
      puts "  Solve once → next #{result["grant_count"]} calls free → re-challenge. Count-based grant demonstrated end-to-end."
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:backoff ───────────────────────────────────────────────────────

  # ── demo:binding ───────────────────────────────────────────────────────────
  desc <<~DESC
    Account-binding walkthrough — a diner links their AI assistant to their
    restaurant account, and the assistant's booking then ties to that account.

    Runs demo:setup (clean DB + seed), boots the server, and runs script/binding_flow.rb,
    which drives BOTH sides of the ceremony over plain HTTP:

      1. The human diner (Diego) signs in through the REAL Devise form
         (/users/sign_in — cookie + CSRF dance) and mints a LINK code
         (POST /kiosk/auth/link, session channel — the human IS the approval).
      2. The assistant, with a FRESH key, redeems the code (POST /kiosk/auth/claim,
         key + possession proof) → a kiosk.agents row is bound to Diego's account.
      3. As that bound token, the assistant books a table for two tomorrow at 8.

    Asserts:
      • the diner signed in via the real Devise form
      • link-code mint (session channel) → 201
      • link-code redeem binds the assistant to the diner's account (user_id == Diego)
      • book_table as the bound token → 200, confirmed
      • the assistant's my_bookings shows the reservation
      • DB ground truth — the load-bearing assertion: bookings.user_id for the
        reservation == Diego's account id (book_table writes under
        kiosk.current_user_id(), which the binding set to the human)
      • DB ground truth: kiosk.agents.user_id for the assistant == Diego's account

    Exits 0 if every assertion holds; exits 1 on failure.
  DESC
  task binding: :setup do
    require "resolv"
    require "json"
    require "shellwords"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-binding.log"
    db   = "kiosk_atablefor_development"
    flow_rb = File.expand_path("../../script/binding_flow.rb", __dir__)
    failures = []

    # The seeded diner (db/seeds.rb) — Diego signs in and mints the link code.
    holder_id       = "00000000-0000-0000-0000-000000000001"
    holder_email    = "diego@example.com"
    holder_password = "atablefor-demo-password"

    host = begin
      addr = Resolv.getaddress("atablefor.demo.kiosk.tech") rescue ""
      addr == "127.0.0.1" ? "atablefor.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (account-binding walkthrough) on #{server_url} ──"

    server_pid = spawn(
      { "KIOSK_ISSUER" => kiosk_issuer },
      "bundle exec rails s -p #{port} -b 127.0.0.1 -e development",
      out: log, err: log,
    )

    require "net/http"
    require "uri"
    begin
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

      puts "\n── Running script/binding_flow.rb ──"
      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape} " \
            "HOLDER_ID=#{holder_id.shellescape} HOLDER_EMAIL=#{holder_email.shellescape} " \
            "HOLDER_PASSWORD=#{holder_password.shellescape}"
      result = atablefor_run_flow(flow_rb, env)

      puts "\n══ Account-binding assertions ══"
      check = lambda do |label, ok|
        if ok then puts "  ✓  #{label}" else failures << label; puts "  ✗  #{label}" end
      end
      check.call("diner signed in via the real Devise form",            result["human_signed_in"] == true)
      check.call("link-code mint (session channel) → 201",              result["link_mint"] == 201)
      check.call("link-code redeem → 201",                              result["link_claim"] == 201)
      check.call("redeem binds the assistant to the diner's account",   result["bound_to_holder"] == true)
      check.call("book_table as the bound token → 200",                 result["wire_book"] == 200)
      check.call("booking is confirmed",                                result["booking_status"] == "confirmed")
      check.call("assistant's my_bookings shows the reservation",       result["my_bookings_has_it"] == true)

      # ── DB ground truth (the load-bearing assertions) ──
      booking_id = result["booking_id"].to_s
      agent_id   = result["agent_id"].to_s
      booking_owner = `psql -X -d #{db} -tAc "SELECT user_id FROM bookings WHERE id = '#{booking_id}'" 2>&1`.strip
      check.call("DB bookings.user_id for the reservation == the diner (#{holder_id})", booking_owner == holder_id)
      agent_owner = `psql -X -d #{db} -tAc "SELECT user_id FROM kiosk.agents WHERE id = '#{agent_id}'" 2>&1`.strip
      check.call("DB kiosk.agents.user_id for the assistant == the diner", agent_owner == holder_id)
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All account-binding assertions PASSED — the assistant's booking ties to the diner's account."
    else
      puts "\n  FAILED:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:binding ───────────────────────────────────────────────────────

  # ---------------------------------------------------------------------------
  desc <<~DESC
    Adversarial cross-tenant isolation test (table-booking domain).

    Boots the server, runs script/isolation_flow.rb with two fresh principals (A and B),
    and asserts all cross-tenant denial properties:

      HEADLINE (owner-scoped cancel): B cannot cancel_booking A's booking.
        A books table oA. B calls cancel_booking with booking_id=oA → MUST be
        403: cancel_booking gates on booking-ownership, so a cross-principal
        cancel is rejected and A's booking stays confirmed.
      Assertion 1 (exclusion): B's my_bookings does NOT contain A's booking oA.
      Assertion 2 (the principal is not an input): B calls book_table with a
        forged user_id arg (A's UUID) → 400 bad_request naming user_id,
        refused by the published input_schema before the handler runs; and B's
        LEGITIMATE booking belongs to B, because ownership comes from the
        token. Verified by:
          - the forged call is refused: 400, code bad_request, detail names user_id
          - the legitimate booking's DB user_id column == B's user_id (not A's)
          - B's my_bookings contains the booking
          - A's my_bookings does NOT contain it

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-isolation.log"

    host = begin
      addr = Resolv.getaddress("atablefor.demo.kiosk.tech") rescue ""
      if addr == "127.0.0.1"
        "atablefor.demo.kiosk.tech"
      else
        puts "  add to /etc/hosts:  127.0.0.1 atablefor.demo.kiosk.tech"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (isolation test) on #{server_url} ──"

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

    flow_rb = File.expand_path("../../script/isolation_flow.rb", __dir__)
    puts "\n── Running script/isolation_flow.rb (adversarial cross-tenant) ──"
    result = atablefor_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}")

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_a             = result["user_id_a"]
    user_id_b             = result["user_id_b"]
    booking_id_a          = result["booking_id_a"]
    booking_id_b          = result["booking_id_b"]
    b_cancel_on_a_status  = result["b_cancel_on_a_status"]
    forged_refusal        = result["forged_refusal"] || []
    b_before              = result["b_booking_ids_before"] || []
    b_after               = result["b_booking_ids_after"]  || []
    a_after               = result["a_booking_ids_after"]  || []

    # ── HEADLINE: B cannot cancel A's booking (owner-scoped gate) ──
    if b_cancel_on_a_status == 403
      puts "  ✓  HEADLINE: B cannot cancel_booking on A's booking (owner-scoped gate) → 403"
    else
      failures << "ISOLATION HOLE: B's cancel_booking on A's booking returned #{b_cancel_on_a_status} (expected 403)"
      puts "  ✗  HEADLINE: cancel_booking ownership gate FAILED — returned #{b_cancel_on_a_status}"
    end

    # ── Assertion 1: B's my_bookings (before) excludes A's booking ────
    if b_before.include?(booking_id_a)
      failures << "ISOLATION HOLE: B's my_bookings (before) contains A's booking #{booking_id_a} — cross-tenant leak"
      puts "  ✗  Assertion 1 FAILED: B sees A's booking #{booking_id_a} — isolation hole"
    else
      puts "  ✓  Assertion 1: B's my_bookings (before) excludes A's booking #{booking_id_a} (app-layer isolation)"
    end

    # ── Assertion 2a: the forged user_id is REFUSED by the published contract ──
    forged_rc, forged_code, forged_detail = forged_refusal
    if forged_rc == 400 && forged_code == "bad_request" && forged_detail.to_s.include?("user_id")
      puts "  ✓  Assertion 2a: forged user_id → 400 bad_request naming user_id " \
           "(refused by input_schema before the handler runs)"
    else
      failures << "forged user_id not refused: #{forged_refusal.inspect}, want [400, \"bad_request\", …user_id…]"
      puts "  ✗  Assertion 2a FAILED: forged user_id → #{forged_refusal.inspect}"
    end

    # ── Assertion 2b: B's my_bookings (after B's own booking) contains oB ──
    if b_after.include?(booking_id_b)
      puts "  ✓  Assertion 2b: B's my_bookings includes B's own booking oB #{booking_id_b}"
    else
      failures << "B's my_bookings does not contain oB #{booking_id_b}; got #{b_after.inspect}"
      puts "  ✗  Assertion 2b FAILED: B's my_bookings missing oB #{booking_id_b}"
    end

    # ── Assertion 2c: A's my_bookings excludes B's booking ──
    if a_after.include?(booking_id_b)
      failures << "ISOLATION HOLE: A's my_bookings contains B's booking #{booking_id_b} — cross-tenant leak"
      puts "  ✗  Assertion 2c FAILED: A sees B's booking #{booking_id_b} — isolation hole"
    else
      puts "  ✓  Assertion 2c: A's my_bookings excludes B's booking #{booking_id_b}"
    end

    # ── Assertion 2d: ownership comes from the TOKEN — DB user_id on oB is B's ──
    db = "kiosk_atablefor_development"
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM bookings WHERE id = '#{booking_id_b}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  ✓  Assertion 2d: DB bookings.user_id for oB == user_id_b (#{user_id_b}) — ownership is taken from the identity"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB bookings.user_id for oB is A's user_id (#{user_id_a}) — the owner did not come from the token"
      puts "  ✗  Assertion 2d FAILED: the booking belongs to A, not to the authenticated B"
    else
      failures << "Unexpected user_id for oB: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  ✗  Assertion 2d FAILED: unexpected user_id #{db_user_id.inspect} for oB"
    end

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
    Self-discovery proof — verifies the schema verb AND the pay-absent capability set.

    Boots the server, runs script/schema_flow.rb (GET /kiosk/schema + /.well-known/kiosk.json
    + /agents.json + /agents.txt).

    Asserts:
      • `GET /kiosk/schema` answers 200 with NO Authorization header (public since T-094)
      • discovery capabilities == [schema, queries, actions] and do NOT include `pay`
        (atablefor takes no payments — a reservation needs none)
      • agents.json carries NO payments block; agents.txt has no ap2 / Payments
      • schema.queries includes availability + my_bookings with descriptions
      • schema.actions includes book_table + cancel_booking with descriptions

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

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-schema.log"

    host = begin
      addr = Resolv.getaddress("atablefor.demo.kiosk.tech") rescue ""
      addr == "127.0.0.1" ? "atablefor.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (schema proof) on #{server_url} ──"

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

    flow_rb = File.expand_path("../../script/schema_flow.rb", __dir__)
    puts "\n── Running script/schema_flow.rb ──"
    result = atablefor_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}")

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
    %w[/ /reservations].each do |page|
      res = Net::HTTP.get_response(URI("#{server_url}#{page}"))
      advertised[%(<link rel="kiosk"> tag)] ||=
        res.body.to_s[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
      advertised[%(Link: <…>; rel="kiosk" header)] ||=
        res["Link"].to_s[/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
    end

    advertised.each do |what, url|
      if url.nil? || url.empty?
        failures << "#{what}: absent from #{%w[/ /reservations].join(", ")} — §4.5's signal is not served"
        puts "  ✗  #{what} absent from #{%w[/ /reservations].join(", ")}"
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

    queries      = result["schema_queries"]        || []
    actions      = result["schema_actions"]        || []
    capabilities = result["discovery_capabilities"] || []

    # ── T-094: the catalogue is PUBLIC, and this is what says so ─────────
    # The flow driver sends NO Authorization header, so this status is the
    # whole access proof; a regression to the Bearer gate reads back as a 401.
    if result["schema_status"] == 200
      puts "  ✓  GET /kiosk/schema answered 200 with NO Authorization header"
    else
      failures << "unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}, want 200"
      puts "  ✗  unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}"
    end

    # ── T-095: ONE origin, ONE publication of the module set ─────────────
    # This used to compare `schema.verbs` with discovery `capabilities` — two
    # fields rendered from the SAME `Array(config.capabilities)` call, so the
    # comparison could only ever pass. `verbs` is gone; the `pay`-absent proof
    # below is against the one document that still carries the set.

    # ── NOT-ONLY-COMMERCE: pay absent from the ADVERTISED capability set ──
    if capabilities.include?("pay")
      failures << "discovery capabilities advertise `pay` (got #{capabilities.inspect}) — atablefor takes no payments"
      puts "  ✗  discovery capabilities include `pay` — must be ABSENT"
    else
      puts "  ✓  discovery capabilities do NOT include `pay` (#{capabilities.inspect}) — a reservation needs no payment"
    end
    %w[schema queries actions].each do |cap|
      if capabilities.include?(cap)
        puts "  ✓  discovery capabilities include #{cap}"
      else
        failures << "discovery capabilities missing #{cap} (got #{capabilities.inspect})"
        puts "  ✗  discovery capabilities missing #{cap}"
      end
    end

    # agents.json / agents.txt carry no payments surface
    if result["agents_json_has_payments"]
      failures << "agents.json carries a payments block — must be absent"
      puts "  ✗  agents.json has a payments block"
    else
      puts "  ✓  agents.json carries NO payments block"
    end
    if result["agents_txt_has_ap2"] || result["agents_txt_has_payments"]
      failures << "agents.txt advertises ap2 / Payments — must be absent"
      puts "  ✗  agents.txt advertises ap2 / Payments"
    else
      puts "  ✓  agents.txt carries no ap2 / Payments directives"
    end

    # Queries: availability, my_bookings with descriptions
    %w[availability my_bookings].each do |qname|
      entry = queries.find { |q| q["name"] == qname }
      if entry && entry["description"] && !entry["description"].to_s.empty?
        puts "  ✓  schema.queries includes #{qname} with a description"
      else
        failures << "schema.queries missing #{qname} (or its description)"
        puts "  ✗  schema.queries missing #{qname} (or its description)"
      end
    end

    # Actions: book_table, cancel_booking with descriptions
    %w[book_table cancel_booking].each do |aname|
      entry = actions.find { |a| a["name"] == aname }
      if entry && entry["description"] && !entry["description"].to_s.empty?
        puts "  ✓  schema.actions includes #{aname} with a description"
      else
        failures << "schema.actions missing #{aname} (or its description)"
        puts "  ✗  schema.actions missing #{aname} (or its description)"
      end
    end

    # T-042 / K-452: the primary read query (availability) and primary action
    # (book_table) advertise the machine-readable descriptor extensions.
    {
      queries => %w[availability],
      actions => %w[book_table],
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
  # ── end demo:schema ───────────────────────────────────────────────────────

  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery.

    Boots atablefor, runs script/redteam_suite.rb and asserts each applicable attack is
    BLOCKED:

      BLOCKED  CrossTenantRead    — B's my_bookings must not include A's booking
      BLOCKED  ForgedUserId       — a forged user_id arg on book_table is REFUSED
                                    (400 bad_request naming it), and B's own
                                    booking never surfaces under A
      BLOCKED  CrossOwnerCancel   — B cancel_booking on A's booking → 403
      BLOCKED  MalformedUuidArg   — a junk booking_id is a typed 400, no SQL leak
      BLOCKED  RegisterWithoutPoP — register without a signed PoP → not 201
      BLOCKED  MissingAuth        — no Authorization → 401
      BLOCKED  GarbageToken       — unparseable bearer → 401
      BLOCKED  SelfAssertedTokenForgery — a self-asserted
                                    `agent:u-…:a-…:r-owner` bearer resolves to
                                    NO identity → 401, unconditionally (T-104)
      BLOCKED  UnknownQuery       — unregistered query name → 404
      BLOCKED  UnknownAction      — unregistered action name → 404
      BLOCKED  RetiredWire        — the deleted 0.3 POST /kiosk/{query,run} → 404
      BLOCKED  MethodMismatch     — GET at an action's path → 405 + Allow: POST
      BLOCKED  InvalidFilterIsNotAnEmptyList — an availability filter naming a
                                    seating that does not exist is a typed 400
                                    NAMING the valid values, never 200 []
      BLOCKED  BookOutsideOfferedHorizon — book_table on a date beyond the
                                    rolling horizon is a typed 400 naming the
                                    bookable dates, never a confirmed booking
                                    for a seating availability never offered;
                                    the basic YYYYMMDD spelling is refused by
                                    the declared format: date (K-767)
      BLOCKED  HostileArgShapes   — boolean/array/object/junk values on
                                    book_table's party_size, restaurant_id,
                                    restaurant_table_id, date and time, on
                                    availability's party_size (bracket
                                    spellings included) and on cancel_booking's
                                    booking_id are a typed 400 carrying no
                                    runtime vocabulary — never a 500, never a
                                    wrong answer served as 200 (K-773, K-1027, K-1028)
      BLOCKED  DeviceGrantRoleSelfSelection — the shared kiosk-redteam beat:
                                    the binding ceremony's unauthenticated
                                    opening request refuses `role`/`scope` at a
                                    DECLARED value as well as an invented one,
                                    and the role-less request still opens it
                                    (K-072, K-1128)

    Exits 0 when all scenarios are BLOCKED (0 BREACH); exits 1 on any BREACH.
    A BREACH = a real hole in atablefor — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "shellwords"
    require "uri"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-atablefor-redteam.log"

    # The two SEEDED diners (db/seeds.rb). The battery binds one assistant to
    # each through the real ceremony (T-104), because the cross-owner beats
    # need two distinct ACCOUNT HOLDERS — two assistants linked to one diner
    # would legitimately see each other's bookings. Credentials travel in the
    # environment rather than sitting in script/redteam_suite.rb, the same way
    # demo:binding passes the holder's.
    holder_a_email    = "diego@example.com"
    holder_b_email    = "bea@example.com"
    holder_password   = "atablefor-demo-password"

    host = begin
      addr = Resolv.getaddress("atablefor.demo.kiosk.tech") rescue ""
      addr == "127.0.0.1" ? "atablefor.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting atablefor (redteam battery) on #{server_url} ──"

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

    suite_rb = File.expand_path("../../script/redteam_suite.rb", __dir__)
    puts "\n── Running script/redteam_suite.rb ──"

    env_str = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape} " \
              "HOLDER_A_EMAIL=#{holder_a_email.shellescape} " \
              "HOLDER_A_PASSWORD=#{holder_password.shellescape} " \
              "HOLDER_B_EMAIL=#{holder_b_email.shellescape} " \
              "HOLDER_B_PASSWORD=#{holder_password.shellescape}"

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

desc "End-to-end Kiosk demo: setup the DB then run the no-human table booking end-to-end."
task demo: ["demo:setup", "demo:book"]
