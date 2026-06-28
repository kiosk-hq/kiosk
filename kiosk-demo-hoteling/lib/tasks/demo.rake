# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-hoteling.
# Tasks:
#
#   rake demo:setup   idempotent db:drop / create / migrate / seed
#   rake demo:book    boots the server, runs hoteling_flow.rb (no-human full
#                     booking chain), asserts happy path + negative gate
#   rake demo         setup + book (full end-to-end proof)

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

  desc "Boot the server, run hoteling_flow.rb end-to-end (happy + payment-gate negative), assert."
  task :book do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"
    require "openssl"

    port = ENV.fetch("PORT", "3004")
    log  = "/tmp/kiosk-hoteling-demo.log"

    # ── host resolution ────────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("hoteling.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "hoteling.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 hoteling.app — using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    db           = "kiosk_hoteling_development"
    flow_rb      = File.expand_path("../../hoteling_flow.rb", __dir__)

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

    # Helper: run hoteling_flow.rb with the given env vars; return parsed JSON result.
    run_flow = lambda do |extra_env = {}|
      env = {
        "SERVER_URL"   => server_url,
        "KIOSK_ISSUER" => kiosk_issuer,
      }.merge(extra_env)
      env_str = env.map { |k, v| "#{k}=#{v.to_s.shellescape}" }.join(" ")
      raw = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
      json_line    = raw.lines.grep(/^\{/).last
      stderr_lines = raw.lines.reject { |l| l.start_with?("{") }
      puts stderr_lines.join
      puts json_line if json_line

      begin
        JSON.parse(json_line || raw)
      rescue JSON::ParserError => e
        abort "hoteling_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
      end
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

      # ── psql assertions ──────────────────────────────────────────────
      b_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM public.bookings WHERE status='confirmed'" 2>&1`.strip
      if b_count.to_i >= 1
        puts "  OK  bookings[status=confirmed] >= 1 (got #{b_count})"
      else
        failures << "happy: bookings[status=confirmed] expected >= 1, got #{b_count.inspect}"
        puts "  FAIL  bookings[status=confirmed] expected >= 1, got #{b_count.inspect}"
      end

      pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates' 2>&1`.strip
      if pm_count.to_i >= 1
        puts "  OK  kiosk.payment_mandates >= 1 (got #{pm_count})"
      else
        failures << "happy: kiosk.payment_mandates expected >= 1, got #{pm_count.inspect}"
        puts "  FAIL  kiosk.payment_mandates expected >= 1, got #{pm_count.inspect}"
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

desc "End-to-end Kiosk hoteling demo: setup the DB then prove the full booking chain."
task demo: ["demo:setup", "demo:book"]
