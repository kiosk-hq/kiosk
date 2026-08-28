# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-hoteling.
# Tasks:
#
#   rake demo:setup      idempotent db:drop / create / schema:load / seed
#   rake demo:book       boots the server, runs script/hoteling_flow.rb (no-human full
#                        booking chain), asserts happy path + negative gate, then runs
#                        script/pay_window.rb in-process (K-853 capture-anchored paid state)
#   rake demo:isolation  adversarial cross-tenant isolation test
#   rake demo:redteam    adversarial regression battery (kiosk-redteam)
#   rake demo:schema     self-discovery proof — verifies the schema verb over HTTP
#   rake demo:browse     browse-heavy priced-pagination PoW demo (KIOSK_POW_BROWSE_DEMO=1)
#   rake demo            setup + book (full end-to-end proof)

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
def hoteling_run_flow(flow_rb, env_str = "", env: {}, runner: "ruby")
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
    # db:schema:load unconditionally (K-712b): db/structure.sql is TRACKED in
    # every demo, so the db:migrate arm this used to branch to was unreachable
    # in every checkout — and under `schema_format = :sql` it would have
    # re-dumped that tracked file, dirtying the worktree. The canonical
    # structure.sql is the source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc "Boot the server, run script/hoteling_flow.rb end-to-end (happy + payment-gate negative), then the " \
       "in-process capture-window regression (script/pay_window.rb, K-853), assert."
  # `: :setup` IS LOAD-BEARING — it is what makes the headline task runnable
  # TWICE (K-1044), and it was the one task of the seven here declared without it.
  #
  # The consequence was measured, not argued: `demo:setup` 0, `demo:book` 0,
  # `demo:book` again **1**, aborting at script/hoteling_flow.rb's "availability
  # returned empty rows". ONE pass consumes the entire inventory the driver can
  # reach. app/controllers/kiosk/hotels_controller.rb renders
  # `Property.order(:name)`, so the driver's `props.first` is deterministically
  # the SAME property every run, and most seeded properties have exactly two room
  # types; script/hoteling_flow.rb pins check_in = today+30 / check_out =
  # today+33, so every run asks for the SAME window; and this task drives the flow
  # TWICE — happy path, then the SKIP_PAY negative — so one invocation takes BOTH
  # room types for that window.
  #
  # The second half is a hold nothing releases. The EXCLUDE constraint
  # `bookings_no_overlapping_room_nights` counts `reserved` as well as
  # `confirmed`, and the SKIP_PAY negative leaves its booking `reserved`/unpaid
  # permanently: app/models/room_hold.rb says outright that `expires_at` is never
  # read back and that the sweep is the operator's (K-936). That posture is
  # decided and documented, so this task may not "fix" the repeat by releasing the
  # hold — and releasing it would not be enough anyway, because the happy path's
  # own room stays `confirmed` while a run needs TWO free room types.
  #
  # So reseeding is the honest remedy, and it is what `isolation`, `redteam`,
  # `schema`, `search` and `browse` in this file already do. DO NOT delete this as
  # "redundant with the job-level demo:setup CI runs": CI is green by
  # construction, and the operator running the headline task a second time is
  # precisely the case that was broken.
  task book: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"
    require "openssl"
    require "shellwords"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-demo.log"

    # ── host resolution ────────────────────────────────────────────────────
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
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.demo.kiosk.tech — using 127.0.0.1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_hoteling_development"
    flow_rb      = File.expand_path("../../script/hoteling_flow.rb", __dir__)

    failures = []

    # Helper: spawn the server, wait for readiness, yield, then kill.
    boot_server = lambda do |&blk|
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

        blk.call
      ensure
        begin
          Process.kill("TERM", server_pid)
          Process.wait(server_pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
        puts "  Server stopped."
      end
    end

    # Helper: run script/hoteling_flow.rb with the given env vars; return parsed JSON result.
    run_flow = lambda do |extra_env = {}|
      env = {
        "SERVER_URL"   => server_url,
        "KIOSK_ISSUER" => kiosk_issuer,
      }.merge(extra_env)
      env_str = env.map { |k, v| "#{k}=#{v.to_s.shellescape}" }.join(" ")
      hoteling_run_flow(flow_rb, env_str)
    end

    # ── RUN 1: Happy path ─────────────────────────────────────────────────
    puts "\n══ RUN 1: Happy path ══"
    boot_server.call do
      result = run_flow.call

      check = lambda do |label, actual, expected|
        if actual == expected
          puts "  OK  #{label} == #{expected}"
        else
          failures << "happy: #{label} expected #{expected}, got #{actual.inspect}"
          puts "  FAIL  #{label} expected #{expected}, got #{actual.inspect}"
        end
      end

      check.call("http_register",       result["http_register"],       201)
      check.call("http_properties",     result["http_properties"],     200)
      check.call("http_availability",   result["http_availability"],   200)
      check.call("http_reserve_room",   result["http_reserve_room"],   200)
      check.call("http_pay",            result["http_pay"],            200)
      check.call("http_confirm_booking", result["http_confirm_booking"], 200)
      check.call("confirm_status",      result["confirm_status"],      "confirmed")

      booking_id = result["booking_id"]
      if booking_id && !booking_id.to_s.empty?
        puts "  OK  booking_id present (#{booking_id})"
      else
        failures << "happy: booking_id missing or empty"
        puts "  FAIL  booking_id missing or empty"
      end

      # ── confirmation_code is PERSISTED, not minted for the response (K-698)
      # It was a fresh SecureRandom.uuid handed to the assistant while the
      # UPDATE wrote only status — against a table with no such column — so the
      # hotel issued a reference it kept no record of and could not match at
      # the desk. Three assertions, because "present" was already true before
      # the fix and proved nothing: the code comes back, my_bookings reports the
      # SAME string afterwards, and the bookings row actually holds it.
      code        = result["confirmation_code"].to_s
      stored_code = result["stored_confirmation_code"].to_s
      if !code.empty? && stored_code == code
        puts "  OK  confirmation_code round-trips through my_bookings (#{code})"
      else
        failures << "happy: confirmation_code #{code.inspect} != my_bookings' #{stored_code.inspect}"
        puts "  FAIL  confirmation_code #{code.inspect} != my_bookings' #{stored_code.inspect}"
      end

      db_code = `psql -X -d #{db} -tAc "SELECT confirmation_code FROM public.bookings WHERE id = '#{booking_id}'" 2>&1`.strip
      if !code.empty? && db_code == code
        puts "  OK  bookings.confirmation_code == the code returned (#{db_code})"
      else
        failures << "happy: bookings.confirmation_code #{db_code.inspect} != returned #{code.inspect}"
        puts "  FAIL  bookings.confirmation_code #{db_code.inspect} != returned #{code.inspect}"
      end

      # ── psql assertions ──────────────────────────────────────────────
      #
      # EACH ASSERTION NAMES THE ROW THIS RUN CREATED (K-862). They used to be
      # DB-wide `COUNT(*) >= 1`, which passes on a row a PREVIOUS run left
      # behind — `demo:setup` is idempotent but nothing forces this task to run
      # straight after it — so the beat under test could stop writing entirely
      # and these three would stay green. The ids are already in hand: the
      # driver reports `booking_id` and its freshly registered `user_id`, and
      # atablefor's demo.rake has asserted by id since K-712f.
      this_status = `psql -X -d #{db} -tAc "SELECT status FROM public.bookings WHERE id = '#{booking_id}'" 2>&1`.strip
      if this_status == "confirmed"
        puts "  OK  this run's booking is confirmed in the DB (id=#{booking_id})"
      else
        failures << "happy: bookings[id=#{booking_id}].status expected 'confirmed', got #{this_status.inspect}"
        puts "  FAIL  bookings[id=#{booking_id}].status — got #{this_status.inspect}"
      end

      # Settlements carry no booking_id, so the anchor is the principal: the
      # driver registers a NEW agent every run, so `user_id` is this run's own
      # and EXACTLY ONE settlement must exist under it (one pay, one receipt).
      user_id  = result["user_id"]
      pm_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM kiosk.settlements WHERE user_id = '#{user_id}'" 2>&1`.strip
      if pm_count.to_i == 1
        puts "  OK  exactly one kiosk.settlements row for this run's principal (#{user_id})"
      else
        failures << "happy: kiosk.settlements for user_id=#{user_id} expected 1, got #{pm_count.inspect}"
        puts "  FAIL  kiosk.settlements for this run's principal — got #{pm_count.inspect}"
      end

      resv_kiosk_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM kiosk.reservations WHERE resource_kind='room_booking' AND resource_id = '#{booking_id}'" 2>&1`.strip
      if resv_kiosk_count.to_i == 1
        puts "  OK  exactly one kiosk.reservations row for THIS booking (#{booking_id})"
      else
        failures << "happy: kiosk.reservations[room_booking, #{booking_id}] expected 1, got #{resv_kiosk_count.inspect}"
        puts "  FAIL  kiosk.reservations for this booking — got #{resv_kiosk_count.inspect}"
      end
    end

    # ── RUN 2: Server-gate negative — SKIP_PAY → 403 ─────────────────────
    puts "\n══ RUN 2: Server-gate negative — SKIP_PAY → 403 ══"
    boot_server.call do
      result = run_flow.call("SKIP_PAY" => "1")

      if result["http_confirm_booking"] == 403
        puts "  OK  SKIP_PAY: http_confirm_booking == 403"
      else
        failures << "skip_pay: http_confirm_booking expected 403, got #{result["http_confirm_booking"].inspect}"
        puts "  FAIL  SKIP_PAY: expected 403, got #{result["http_confirm_booking"].inspect}"
      end
    end

    # ── RUN 3: the capture→settlement window (K-853 / protocol.md §11.6) ──
    # NO SERVER. The two halves of the window cannot be stood in over HTTP —
    # holding a capture mid-charge and observing a returned capture with no
    # settlement row need a controllable PSP and the provider called directly —
    # so this run is IN-PROCESS against the same database, driving the real
    # verbs through the registry the wire dispatches to. It rides inside
    # demo:book rather than becoming its own task because demo:book is already
    # this demo's pay-path gate.
    puts "\n══ RUN 3: capture-anchored paid state (K-853) ══"
    window_rb = File.expand_path("../../script/pay_window.rb", __dir__)
    unless system("bundle exec rails runner #{window_rb.shellescape}")
      failures << "pay_window: capture-window assertions failed (see output above)"
    end

    # ── final verdict ─────────────────────────────────────────────────────
    puts "\n── Assertions ──"
    if failures.empty?
      puts "  All assertions passed."
    else
      puts "  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
end

namespace :demo do
  # ── demo:isolation ──────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial cross-tenant isolation test.

    Runs demo:setup (clean DB + seed), boots the server, runs script/isolation_flow.rb
    with two fresh principals (A and B), and asserts all cross-tenant denial
    properties:

      Assertion 1 (ownership denial — Gate-1 isolated): B settles a payment
        mandate referencing A's booking (Gate-2 ✓) then calls confirm_booking
        on A's booking_id. Gate-1 (user_id = kiosk.current_user_id() AND
        status='reserved') finds nothing → 403. The 403 isolates Gate-1
        because Gate-2 is genuinely satisfied by B.
      Assertion 2a (exclusion): B's my_bookings does NOT contain A's booking.
      Assertion 2b (positive control): B's my_bookings DOES contain B's own
        booking, proving the exclusion is not vacuous.
      Assertion 3a (the principal is not an input): B calls reserve_room with a
        forged user_id arg (A's UUID) -> 400 bad_request naming user_id,
        refused by the published input_schema before the handler runs.
      Assertion 3b (ownership comes from the token): B's legitimate booking has
        DB user_id == B, because the INSERT reads kiosk.current_user_id() and
        never an argument — the property the refusal alone does not prove.

    Exits 0 if all assertions hold (isolation works); exits 1 on failure.
    A red assertion = real isolation hole: fix the app, not the test.
  DESC
  task isolation: :setup do
    require "resolv"
    require "json"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-isolation.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.demo.kiosk.tech — using 127.0.0.1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_hoteling_development"

    puts "\n── Starting hoteling (isolation test) on #{server_url} ──"

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

    flow_rb = File.expand_path("../../script/isolation_flow.rb", __dir__)
    puts "\n── Running script/isolation_flow.rb (adversarial cross-tenant) ──"
    result = hoteling_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}")

    failures = []
    puts "\n── Adversarial isolation assertions ──"

    user_id_a            = result["user_id_a"]
    user_id_b            = result["user_id_b"]
    booking_id_a         = result["booking_id_a"]
    booking_id_b         = result["booking_id_b"]
    forged_refusal       = result["forged_refusal"] || []
    b_confirm_booking_rc = result["b_confirm_booking_rc"]
    b_booking_ids        = result["b_booking_ids"] || []

    # ── Assertion 1: B's confirm_booking on A's booking → 403 ────────────
    # B paid for rA (Gate-2 ✓); the 403 isolates Gate-1 ownership exclusively.
    if b_confirm_booking_rc == 403
      puts "  OK  Assertion 1: B's confirm_booking on A's #{booking_id_a} → 403 " \
           "(Gate-1 ownership denied; Gate-2 payment satisfied)"
    else
      failures << "ISOLATION HOLE: B's confirm_booking on A's booking returned " \
                  "#{b_confirm_booking_rc.inspect} (expected 403) — Gate-1 ownership bypass"
      puts "  FAIL  Assertion 1: B's confirm_booking on A's booking expected 403, " \
           "got #{b_confirm_booking_rc.inspect} — isolation hole"
    end

    # ── Assertion 2a: B's my_bookings excludes A's booking ───────────────
    if b_booking_ids.include?(booking_id_a)
      failures << "ISOLATION HOLE: B's my_bookings contains A's booking #{booking_id_a} — cross-tenant leak"
      puts "  FAIL  Assertion 2a: B sees A's booking #{booking_id_a} in my_bookings — isolation hole"
    else
      puts "  OK  Assertion 2a: B's my_bookings excludes A's booking #{booking_id_a} (app-layer isolation)"
    end

    # ── Assertion 2b: B's my_bookings includes B's own booking ───────────
    if b_booking_ids.include?(booking_id_b)
      puts "  OK  Assertion 2b: B's my_bookings includes B's own #{booking_id_b} " \
           "(positive control — exclusion non-vacuous)"
    else
      failures << "B's my_bookings does not include B's own booking #{booking_id_b}; " \
                  "got #{b_booking_ids.inspect} — positive control failed (vacuous exclusion)"
      puts "  FAIL  Assertion 2b: B's my_bookings missing B's own #{booking_id_b} " \
           "— positive control failed"
    end

    # ── Assertion 3a: the forged user_id is REFUSED by the published contract.
    # On the 0.4 wire `reserve_room` publishes `additionalProperties: false` and
    # does not declare `user_id` — the principal is not one of its inputs — so
    # the forgery is a typed 400 naming the parameter, before the handler runs.
    # (Through 0.3 the argument was accepted and silently ignored, and the desc
    # said so; that sentence is now false.)
    forged_rc, forged_code, forged_detail = forged_refusal
    if forged_rc == 400 && forged_code == "bad_request" && forged_detail.to_s.include?("user_id")
      puts "  OK  Assertion 3a: forged user_id → 400 bad_request naming user_id " \
           "(refused by input_schema before the handler runs)"
    else
      failures << "forged user_id not refused: #{forged_refusal.inspect}, " \
                  "want [400, \"bad_request\", …user_id…]"
      puts "  FAIL  Assertion 3a: forged user_id → #{forged_refusal.inspect}"
    end

    # ── Assertion 3b: ownership comes from the TOKEN — DB user_id == B ───
    db_user_id = `psql -X -d #{db} -tAc "SELECT user_id FROM public.bookings WHERE id = '#{booking_id_b}'" 2>&1`.strip
    if db_user_id == user_id_b
      puts "  OK  Assertion 3b: DB bookings.user_id for rB == user_id_b (#{user_id_b}) — ownership taken from the identity"
    elsif db_user_id == user_id_a
      failures << "ISOLATION HOLE: DB bookings.user_id for rB is A's user_id (#{user_id_a}) " \
                  "— ownership was not taken from the authenticated identity"
      puts "  FAIL  Assertion 3b: booking belongs to A, not B"
    else
      failures << "Unexpected user_id for rB: got #{db_user_id.inspect}, expected B's #{user_id_b}"
      puts "  FAIL  Assertion 3b: unexpected user_id #{db_user_id.inspect} for rB"
    end

    if failures.empty?
      puts "\n  All adversarial assertions passed — app-layer isolation holds."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:isolation ─────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:redteam ─────────────────────────────────────────────────────────
  desc <<~DESC
    Adversarial regression battery — kiosk-redteam.

    Boots hoteling, runs the generic Kiosk::Redteam scenarios plus hoteling's
    own beats against the chain (register PoW → no KYC → reserve_room → pay →
    confirm_booking) and asserts each applicable attack is BLOCKED. The suite
    prints the count it actually ran; this list names them. No count is kept
    here on purpose: a count kept here is a count that rots (K-710, and the
    guard commissioned by T-078 will diff this list against the suite's own
    registry):

      BLOCKED  PayForOtherUseSelf    — C2: B pays for A's booking, tries confirm_booking
      BLOCKED  SpentResourceReuse    — C3: re-confirm an already-confirmed booking
      BLOCKED  UnpaidGatedAction     — confirm_booking without payment → Gate-2 fires
      BLOCKED  CrossTenantRead       — B's my_bookings excludes A's rows
      BLOCKED  ForgedUserId          — agent-supplied user_id in reserve_room args refused
                                       (0.4: undeclared argument → typed 400 before the handler)
      BLOCKED  MandatePrincipalSwap  — B signs mandate with A's identity; rejected
      BLOCKED  MandateReplay         — B re-submits A's JWS; rejected
      BLOCKED  TokenTampering        — altered JWT claim rejected 401
      BLOCKED  PrivilegeSelfSelection — client-chosen registration role ignored (server-pinned)
      BLOCKED  DeviceGrantRoleSelfSelection — the binding ceremony's unauthenticated
                                       opening request refuses `role`/`scope`, at a
                                       DECLARED value as well as an invented one (K-072)
      BLOCKED  RegistrationWithoutPow — register without a proof rejected (register PoW is ON)
      BLOCKED  WrongCurrencyCart     — usd cart at a EUR operator refused at capture
      BLOCKED  TamperedPriceCart     — below-quote total refused at capture
      BLOCKED  InflatedTotalCart     — total above the line-item sum refused at capture
      BLOCKED  MalformedUuidArg      — junk booking_id → typed 400, no SQL internals, never a 500
      BLOCKED  HostileArgShapes      — every hostile SHAPE on the integer and date arguments
                                       (boolean, array, object, junk integer, unparseable
                                       and out-of-horizon date), plus MAGNITUDE — a filter
                                       one past PostgreSQL `integer` (T-125) → typed 400,
                                       never a 500 and never a wrong answer served as 200
                                       (K-773, K-1047)
      BLOCKED  DoubleBookedRoom      — a held room-night cannot be re-reserved → 409
      BLOCKED  RetiredWire           — POST /kiosk/query and /kiosk/run are the ordinary 404
                                       an authenticated caller gets, 401 without a bearer
                                       (the 0.3 pair was DELETED, not shimmed — T-074 = A)
      BLOCKED  MethodMismatch        — a GET at an action's path is 405 method_not_allowed
                                       with Allow:, never a silent 404
      BLOCKED  PastStay              — a check_in before today is a typed 400 on BOTH
                                       availability and reserve_room — never rooms,
                                       never a hold (K-969)
      SKIPPED  MissingKyc            — hoteling has no KYC gate
      SKIPPED  ExpiredKyc            — hoteling has no KYC gate
      SKIPPED  ForgedKyc             — hoteling has no KYC gate

    Exits 0 when all applicable scenarios are BLOCKED and skips match expectations.
    A BREACH = a real hole in hoteling — fix the app, not the scenario.
  DESC
  task redteam: :setup do
    require "resolv"
    require "json"
    require "net/http"
    require "uri"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-redteam.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.demo.kiosk.tech"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.demo.kiosk.tech — using 127.0.0.1)"
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting hoteling (redteam battery) on #{server_url} ──"

    env_vars = { "KIOSK_ISSUER" => kiosk_issuer }

    File.truncate(log, 0) if File.exist?(log)
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

namespace :demo do
  # ── demo:schema ─────────────────────────────────────────────────────────────
  desc <<~DESC
    Self-discovery proof — verifies the schema verb over HTTP.

    Boots the server, registers a fresh agent (registration IS PoW-gated —
    registration_pow_count = 1 — and the flow solves it transparently), calls:
      GET /kiosk/schema

    Asserts:
      • `GET /kiosk/schema` answers 200 with NO Authorization header (public since T-094)
      • the MODULE set lives in /.well-known/kiosk.json `capabilities` (`verbs` dropped, T-095)
      • capabilities is the MODULE set schema/queries/actions/pay and NOT events
      • schema.queries includes properties, availability, my_bookings with descriptions
      • schema.actions includes reserve_room, confirm_booking, payment_setup with descriptions
      • `payment_setup` publishes BOTH a backing-off poll cadence and a GIVE UP horizon (K-606)

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

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-schema.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      addr == "127.0.0.1" ? "hoteling.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting hoteling (schema proof) on #{server_url} ──"

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
    result = hoteling_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}")

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

    queries      = result["schema_queries"] || []
    actions      = result["schema_actions"] || []
    capabilities = result["discovery_capabilities"] || []

    # THE SCHEMA CALL WAS MADE WITHOUT A CREDENTIAL (T-094). The flow driver
    # sends no Authorization header, so this status IS the public-access proof.
    if result["schema_status"] == 200
      puts "  OK  GET /kiosk/schema answered 200 with NO Authorization header"
    else
      failures << "unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}, want 200"
      puts "  FAIL  unauthenticated GET /kiosk/schema returned #{result["schema_status"].inspect}"
    end

    # THE MODULE SET, at its one remaining home. It was published twice —
    # `schema.verbs` and `kiosk.json` `capabilities` — from the same call, so
    # `verbs` was dropped (T-095) and the property moved here intact.
    %w[schema queries actions pay].each do |v|
      if capabilities.include?(v)
        puts "  OK  capabilities includes #{v}"
      else
        failures << "capabilities missing #{v} (got #{capabilities.inspect})"
        puts "  FAIL  capabilities missing #{v}"
      end
    end
    if capabilities.include?("events")
      failures << "capabilities must NOT include events (got #{capabilities.inspect})"
      puts "  FAIL  capabilities must NOT include events"
    else
      puts "  OK  capabilities does not include events"
    end

    # Queries: properties, availability, my_bookings, search_hotels, hotel_detail
    %w[properties availability my_bookings search_hotels hotel_detail].each do |qname|
      entry = queries.find { |q| q["name"] == qname }
      if entry
        puts "  OK  schema.queries includes #{qname}"
        if entry["description"] && !entry["description"].to_s.empty?
          puts "  OK  #{qname} has description: #{entry["description"].inspect[0, 80]}…"
        else
          failures << "#{qname} missing description"
          puts "  FAIL  #{qname} missing description"
        end
      else
        failures << "schema.queries missing #{qname}"
        puts "  FAIL  schema.queries missing #{qname}"
      end
    end

    # T-042 / K-452: the two data-plane exemplar queries carry the machine-readable
    # descriptor extensions (input_schema + example_params + example_row).
    %w[search_hotels hotel_detail].each do |qname|
      entry = queries.find { |q| q["name"] == qname } || {}
      %w[input_schema example_params example_row].each do |ext|
        if entry[ext] && !entry[ext].to_s.empty?
          puts "  OK  #{qname} advertises #{ext}"
        else
          failures << "#{qname} missing #{ext}"
          puts "  FAIL  #{qname} missing #{ext}"
        end
      end
    end

    # Actions: reserve_room, confirm_booking, payment_setup with descriptions
    %w[reserve_room confirm_booking payment_setup].each do |aname|
      entry = actions.find { |a| a["name"] == aname }
      if entry
        puts "  OK  schema.actions includes #{aname}"
        if entry["description"] && !entry["description"].to_s.empty?
          puts "  OK  #{aname} has description: #{entry["description"].inspect}"
        else
          failures << "#{aname} missing description"
          puts "  FAIL  #{aname} missing description"
        end
      else
        failures << "schema.actions missing #{aname}"
        puts "  FAIL  schema.actions missing #{aname}"
      end
    end

    # ── K-606: THE POLL BUDGET IS A PUBLISHED CONTRACT, SO IT IS ASSERTED ─────
    # The out-of-band verbs below are learned about by RE-POLLING and nothing
    # else — the wire has no server→assistant push — so K-477/K-595 wrote a
    # cadence and a give-up horizon into their descriptors and K-605 made them
    # QUOTE kiosk.tech/skill.md's tiered schedule instead of a rival flat one.
    # Until this beat nothing that runs read either back: `grep` found the
    # strings only in the source they were written into, so any later edit could
    # drop the horizon and every gate stayed green. It is asserted here, on the
    # SERVED descriptor, because that is the document an assistant reads.
    #
    # STRUCTURE, NOT THE MINUTES. Both tiers must be present, the second must be
    # SLOWER than the first (a tiering that is not one is not a schedule), and a
    # horizon must be named in minutes. The exact numbers are deliberately NOT
    # pinned: writing "5" and "15" here would make this file a third place the
    # schedule lives, which is the divergence K-605 closed by deleting a derived
    # count rather than recomputing it.
    poll_tiers   = /re-check every ~(\d+) seconds for the first minute, then every ~(\d+) seconds/
    poll_horizon = /GIVE UP after about (\d+) minutes?/
    { actions => ["payment_setup"] }.each do |list, names|
      names.each do |vname|
        entry = list.find { |e| e["name"] == vname }
        if entry.nil?
          failures << "schema is missing #{vname} — the poll-budget assertion cannot run (K-606)"
          puts "  FAIL  schema is missing #{vname} (K-606)"
          next
        end
        desc = entry["description"].to_s
        tiers   = desc.match(poll_tiers)
        horizon = desc.match(poll_horizon)
        if tiers.nil?
          failures << "#{vname} description publishes no poll cadence (K-477/K-605): #{desc.inspect}"
          puts "  FAIL  #{vname} publishes no poll cadence"
        elsif tiers[2].to_i <= tiers[1].to_i
          failures << "#{vname} cadence does not back off: ~#{tiers[1]}s then ~#{tiers[2]}s (K-605)"
          puts "  FAIL  #{vname} cadence does not back off (~#{tiers[1]}s then ~#{tiers[2]}s)"
        else
          puts "  OK    #{vname} publishes a backing-off cadence (~#{tiers[1]}s, then ~#{tiers[2]}s)"
        end
        if horizon.nil? || horizon[1].to_i <= 0
          failures << "#{vname} description publishes no GIVE UP horizon (K-477): #{desc.inspect}"
          puts "  FAIL  #{vname} publishes no GIVE UP horizon"
        else
          puts "  OK    #{vname} publishes a give-up horizon (~#{horizon[1]} minutes)"
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
  # ── end demo:schema ─────────────────────────────────────────────────────────
end

namespace :demo do
  # ── demo:search ─────────────────────────────────────────────────────────────
  desc <<~DESC
    Pagination + detail-by-id proof (T-042 / K-452).

    Boots the server over the ~100-hotel catalogue, registers a fresh agent, and
    runs script/search_flow.rb to PROVE the data-plane pagination shape:

      • search_hotels with a small limit returns a FULL page — a BARE ARRAY —
        carrying an RFC 8288 `Link: <…>; rel="next"` header (truncated) and an
        `X-Total-Count` larger than the page.
      • FOLLOWING that link verbatim returns the FOLLOWING page, and the two
        pages are DISJOINT (real paging, not the same slice).
      • a filtered search that fits in one page is the SAME bare array with no
        `Link` at all (complete result — the link's absence is the signal).
      • hotel_detail on a summary row's id returns a ONE-ROW ARRAY carrying the
        full property with rooms (the "search returns summaries, fetch detail on
        demand" pattern; K-794 made it answer rows like every other query), and
        an id nobody has is 404 not_found on BOTH hotel_detail and availability
        (T-090: that argument addresses a property, so an empty list would be a
        false statement rather than an empty result).
      • §9.1's bad-argument rule in ALL THREE branches, which is one
        discriminator rather than three checks (K-821): an addressed-but-absent
        `property_id` is 404 (above), a FILTER that matched nothing is 200 with
        an empty array, and a value outside its declared domain is 400 whose
        detail NAMES THE VALID VALUES.

    Exits 0 if all assertions pass; exits 1 on any miss.
  DESC
  task search: :setup do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-hoteling-search.log"

    host = begin
      addr = begin
        Resolv.getaddress("hoteling.demo.kiosk.tech")
      rescue Resolv::ResolvError
        ""
      end
      addr == "127.0.0.1" ? "hoteling.demo.kiosk.tech" : "127.0.0.1"
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting hoteling (pagination proof) on #{server_url} ──"

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

    flow_rb = File.expand_path("../../script/search_flow.rb", __dir__)
    puts "\n── Running script/search_flow.rb ──"
    result = hoteling_run_flow(flow_rb, "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}")

    puts "\n── Pagination + detail assertions ──"
    failures = []

    check = lambda do |ok, pass_msg, fail_msg|
      if ok
        puts "  OK  #{pass_msg}"
      else
        failures << fail_msg
        puts "  FAIL  #{fail_msg}"
      end
    end

    check.call(result["http_page1"] == 200, "search_hotels page 1 → 200", "page 1 HTTP #{result["http_page1"].inspect}")

    # THE pagination proof (T-092): every page is a BARE ARRAY; a truncated one
    # carries `Link: …; rel="next"`; following that link verbatim returns a
    # DISJOINT next page; the last (filtered, complete) page carries no link.
    check.call(result["page1_count"] == 20,
               "page 1 is a full page of 20 rows", "page 1 count #{result["page1_count"].inspect} (expected 20)")
    check.call(result["page1_is_array"] == true,
               "page 1 is a BARE ARRAY — a paginating query has no shape of its own",
               "page 1 is not a bare array (#{result["page1_is_array"].inspect}) — the " \
               "`{rows, next}` object was supposed to go with RFC 8288")
    check.call(!result["page1_next"].to_s.empty?,
               "page 1 carries Link rel=\"next\" (truncated) — #{result["page1_next"].inspect}",
               "page 1 has no Link rel=\"next\" — truncation is silent")
    check.call(result["page1_total"].to_i > result["page1_count"].to_i,
               "X-Total-Count (#{result["page1_total"].inspect}) counts the MATCHING set, " \
               "not the page (#{result["page1_count"]})",
               "X-Total-Count #{result["page1_total"].inspect} is not larger than the page " \
               "#{result["page1_count"].inspect} — it must count matching rows, never returned ones")
    check.call(result["page2_count"].to_i >= 1 && result["pages_disjoint"] == true,
               "FOLLOWING the Link target returns a DISJOINT next page (#{result["page2_count"]} rows)",
               "next page empty or overlapping (count=#{result["page2_count"].inspect}, disjoint=#{result["pages_disjoint"].inspect})")
    check.call(result["filtered_has_next"] == false && result["filtered_is_array"] == true,
               "the filtered (complete) search is the SAME bare array and carries no Link " \
               "(#{result["filtered_count"]} rows)",
               "filtered search is not a bare array without a `next` link " \
               "(array=#{result["filtered_is_array"].inspect}, link=#{result["filtered_has_next"].inspect}) " \
               "— cannot signal completeness")
    check.call(result["filtered_total"].to_i == result["filtered_count"].to_i,
               "a COMPLETE answer's X-Total-Count equals its row count (#{result["filtered_count"]})",
               "complete answer X-Total-Count #{result["filtered_total"].inspect} != " \
               "row count #{result["filtered_count"].inspect}")

    # detail-by-id: search returns summaries, fetch detail on demand.
    check.call(result["http_detail"] == 200 && result["detail_room_count"].to_i >= 1,
               "hotel_detail(id=#{result["detail_id"]}) → full property, #{result["detail_room_count"]} room type(s)",
               "hotel_detail failed (http=#{result["http_detail"].inspect}, rooms=#{result["detail_room_count"].inspect})")

    # K-794: a detail-by-id query is still a query, so it answers ROWS — a
    # one-element array, not a bare object. Both halves are asserted, because
    # the shape without the empty case would leave "no such hotel" undefined.
    check.call(result["detail_is_array"] == true && result["detail_row_count"] == 1,
               "hotel_detail answers a ONE-ROW ARRAY (spec §8.2)",
               "hotel_detail is not a one-row array " \
               "(array=#{result["detail_is_array"].inspect}, rows=#{result["detail_row_count"].inspect})")
    # T-090 / spec §9.1: `property_id` ADDRESSES a property, so an id nobody has
    # is 404 — on BOTH verbs that take it. The pair used to disagree, which is
    # what made the rule Phil's call.
    check.call(result["http_unknown_detail"] == 404 &&
               result["unknown_detail_code"] == "not_found",
               "hotel_detail for an id nobody has → 404 not_found",
               "hotel_detail for an unknown id answered " \
               "http=#{result["http_unknown_detail"].inspect} " \
               "code=#{result["unknown_detail_code"].inspect} (want 404 / not_found)")
    check.call(result["http_unknown_availability"] == 404 &&
               result["unknown_availability_code"] == "not_found",
               "availability for the SAME unknown id → 404 not_found (the two verbs agree)",
               "availability for an unknown id answered " \
               "http=#{result["http_unknown_availability"].inspect} " \
               "code=#{result["unknown_availability_code"].inspect} (want 404 / not_found)")

    # ── §9.1's THREE-WAY BAD-ARGUMENT RULE, ALL THREE BRANCHES (K-821) ──────
    #
    # The two checks above are rule 2 («a well-formed IDENTIFIER of a resource
    # that does not exist is 404»). The rule has three branches and they are ONE
    # discriminator — «does this argument ADDRESS an entity or FILTER a
    # collection?» — so any one of them checked alone proves very little: an
    # origin that answered 404 to every miss, or `200 []` to every miss, would
    # pass a single-branch check and be exactly the origin an assistant cannot
    # tell a typo from a sold-out night on. hoteling implements all three and,
    # until this run, tested none: the comment at
    # app/operations/operation_result.rb:28 records that the `not_found`
    # mapping was already REMOVED ONCE and restored, by an edit no test caught.
    check.call(result["http_empty_filter"] == 200 &&
               result["empty_filter_is_array"] == true &&
               result["empty_filter_count"] == 0,
               "rule 3: a FILTER that matched nothing → 200 with an EMPTY array",
               "an unsatisfiable filter answered http=#{result["http_empty_filter"].inspect} " \
               "array=#{result["empty_filter_is_array"].inspect} " \
               "rows=#{result["empty_filter_count"].inspect} (want 200 / [])")
    # `== 0`, not `.to_i == 0`: an ABSENT header parses to nil and `nil.to_i`
    # is 0, so the lenient form passes when the wire says nothing at all.
    check.call(result["empty_filter_total"] == 0,
               "…and X-Total-Count says the MATCHING SET is empty, not just this page",
               "empty filter reported X-Total-Count #{result["empty_filter_total"].inspect} " \
               "(want the header, carrying 0) — an empty page of a non-empty set, or no " \
               "header at all, is a different statement")
    # The control. `0 rows` is also what a broken filter, an unseeded database
    # or a mis-decoded cursor produces; the same neighbourhood WITHOUT the
    # impossible price cap must return rows, or the line above proves nothing.
    check.call(result["control_filter_count"].to_i.positive?,
               "…control: the same filter without the impossible price returns " \
               "#{result["control_filter_count"]} rows",
               "the control search returned #{result["control_filter_count"].inspect} rows — " \
               "the empty result above cannot be attributed to the price cap")

    check.call(result["http_bad_enum"] == 400 && result["bad_enum_code"] == "bad_request",
               "rule 1: a value OUTSIDE its declared domain → 400 bad_request",
               "an out-of-domain neighbourhood answered http=#{result["http_bad_enum"].inspect} " \
               "code=#{result["bad_enum_code"].inspect} (want 400 / bad_request)")
    # THE HALF THAT MAKES THE 400 USABLE. §9.1 rule 1 does not stop at the
    # status: the `detail` or `hint` MUST NAME THE VALID VALUES, because that
    # sentence is the entire recovery path an assistant has when it guessed a
    # value wrong — without it the only way back is to refetch the catalogue.
    check.call(result["bad_enum_names_values"] == true,
               "…and the refusal NAMES THE VALID VALUES an assistant may retry with",
               "the 400's detail does not list the accepted neighbourhoods: " \
               "#{result["bad_enum_detail"].inspect}")
    # Non-vacuity: a `detail` that merely echoed the request would contain a
    # neighbourhood name too. It must be listing the DOMAIN, not the input.
    check.call(result["bad_enum_echoes_bad_value"] == false,
               "…and it lists the DOMAIN rather than echoing what was sent",
               "the 400's detail contains the rejected value itself, so 'names the valid " \
               "values' may be satisfied by an echo: #{result["bad_enum_detail"].inspect}")

    if failures.empty?
      puts "\n  All pagination + detail assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
  # ── end demo:search ─────────────────────────────────────────────────────────
end

desc "End-to-end Kiosk hoteling demo: setup the DB then prove the full booking chain."
task demo: ["demo:setup", "demo:book"]

namespace :demo do
  desc <<~DESC
    Browse-heavy priced-pagination PoW demo (KIOSK_POW_BROWSE_DEMO=1).

    Boots the server with the browse gate active and runs script/browse_flow.rb: a
    burst of `properties` queries where the first few are free and each extra
    one costs escalating proof-of-work (price depth, don't ban it).

    Asserts: a non-empty free prefix, the demanded proof count becomes positive,
    and the curve is monotonic non-decreasing. Requires python3 + numpy.
  DESC
  task browse: :setup do
    require "net/http"; require "uri"; require "json"; require "shellwords"

    python_ok = system("python3 -c 'import numpy' 2>/dev/null")
    abort "numpy not found. Install with: pip install numpy" unless python_ok

    port         = ENV.fetch("PORT", "3003")
    server_url   = "http://127.0.0.1:#{port}"
    kiosk_issuer = server_url
    log          = "/tmp/kiosk-hoteling-browse.log"
    flow_rb      = File.expand_path("../../script/browse_flow.rb", __dir__)
    failures     = []

    File.truncate(log, 0) if File.exist?(log)
    server_pid = spawn(
      { "KIOSK_ISSUER" => kiosk_issuer, "KIOSK_POW_BROWSE_DEMO" => "1" },
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
      puts "  Server up at #{server_url} (browse gate active)"

      env = "SERVER_URL=#{server_url.shellescape} KIOSK_ISSUER=#{kiosk_issuer.shellescape}"
      result = hoteling_run_flow(flow_rb, env)

      puts "\n══ Browse priced-pagination assertions ══"
      puts "  Proof-count curve: #{result["curve"].inspect}"

      if result["free_prefix"].to_i >= 1
        puts "  OK  free prefix (#{result["free_prefix"]} queries served without PoW)"
      else
        failures << "expected a non-empty free prefix, curve=#{result["curve"].inspect}"
        puts "  FAIL  no free prefix"
      end
      if result["became_priced"]
        puts "  OK  depth got priced (proof count rose above 0)"
      else
        failures << "expected the proof count to become positive, curve=#{result["curve"].inspect}"
        puts "  FAIL  browsing never got priced"
      end
      if result["monotonic"]
        puts "  OK  proof count is monotonic non-decreasing"
      else
        failures << "expected a monotonic curve, got #{result["curve"].inspect}"
        puts "  FAIL  proof count not monotonic"
      end
    ensure
      begin
        Process.kill("TERM", server_pid); Process.wait(server_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      puts "  Server stopped."
    end

    if failures.empty?
      puts "\n  All browse assertions PASSED — depth priced, not banned."
    else
      puts "\n  FAILED:"; failures.each { |f| puts "    - #{f}" }; exit 1
    end
  end
end
