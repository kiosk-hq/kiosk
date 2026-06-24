# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-skooti. Tasks:
#
#   rake demo:setup      idempotent db:drop / create / migrate / seed
#   rake demo:rideflow   boots the server, runs unlock_flow.rb (no-human full
#                        unlock chain), asserts happy path + negative gates,
#                        tears down
#   rake demo            setup + rideflow (full end-to-end proof)
#
# The walkthrough lives in bin/demo (POSIX shell) so it's debuggable
# without going through Rake.

namespace :demo do
  desc "Create + migrate + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    sh "bundle exec rails db:drop db:create db:migrate db:seed"
  end

  desc "Boot the server, run unlock_flow.rb end-to-end (happy + negative gates), assert."
  task :rideflow do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port = ENV.fetch("PORT", "3003")
    log  = "/tmp/kiosk-skooti-demo.log"

    # ── host resolution ────────────────────────────────────────────────────
    host = begin
      addr = begin
        Resolv.getaddress("skooti.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "skooti.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 skooti.app — using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url
    master_key   = ENV.fetch("MASTER_KEY", "dev-master-key-0001")
    db           = "kiosk_skooti_development"
    flow_rb      = File.expand_path("../../unlock_flow.rb", __dir__)

    failures = []

    # Helper: spawn the server, wait for readiness, yield, then kill.
    boot_server = lambda do |&blk|
      File.truncate(log, 0) if File.exist?(log)
      server_pid = spawn(
        { "KIOSK_ISSUER" => kiosk_issuer, "SKOOTI_MASTER_KEY" => master_key },
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

    # ── RUN 1: Happy path ─────────────────────────────────────────────────
    puts "\n══ Happy path ══"
    boot_server.call do
      env = {
        "SERVER_URL"       => server_url,
        "KIOSK_ISSUER"     => kiosk_issuer,
        "MASTER_KEY"       => master_key,
      }
      env_str = env.map { |k, v| "#{k}=#{v}" }.join(" ")
      raw = `#{env_str} bundle exec ruby #{flow_rb} 2>&1`
      # Separate JSON line (stdout) from STDERR progress lines.
      json_line = raw.lines.grep(/^\{/).last
      stderr_lines = raw.lines.reject { |l| l.start_with?("{") }
      puts stderr_lines.join
      puts json_line if json_line

      begin
        result = JSON.parse(json_line || raw)
      rescue JSON::ParserError => e
        abort "unlock_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
      end

      if result["http_unlock"] == 200
        puts "  ✓  http_unlock == 200"
      else
        failures << "happy: http_unlock expected 200, got #{result["http_unlock"].inspect}"
        puts "  ✗  http_unlock expected 200, got #{result["http_unlock"].inspect}"
      end

      if result["unlocked"] == true
        puts "  ✓  unlocked == true"
      else
        failures << "happy: unlocked expected true, got #{result["unlocked"].inspect}"
        puts "  ✗  unlocked — got #{result["unlocked"].inspect}"
      end

      if result["replay_rejected"] == true
        puts "  ✓  replay_rejected == true"
      else
        failures << "happy: replay_rejected expected true, got #{result["replay_rejected"].inspect}"
        puts "  ✗  replay_rejected — got #{result["replay_rejected"].inspect}"
      end

      if result["tamper_rejected"] == true
        puts "  ✓  tamper_rejected == true"
      else
        failures << "happy: tamper_rejected expected true, got #{result["tamper_rejected"].inspect}"
        puts "  ✗  tamper_rejected — got #{result["tamper_rejected"].inspect}"
      end

      mac = result["mac"]
      if mac && !mac.empty?
        puts "  ✓  mac present (#{mac[0, 16]}…)"
      else
        failures << "happy: mac missing or empty"
        puts "  ✗  mac missing or empty"
      end

      # ── psql assertions ────────────────────────────────────────────────
      res_count = `psql -X -d #{db} -tAc "SELECT COUNT(*) FROM public.reservations WHERE status='active'" 2>&1`.strip
      if res_count.to_i >= 1
        puts "  ✓  reservations[status=active] >= 1 (got #{res_count})"
      else
        failures << "happy: reservations[status=active] expected >= 1, got #{res_count.inspect}"
        puts "  ✗  reservations[status=active] expected >= 1, got #{res_count.inspect}"
      end

      pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates' 2>&1`.strip
      if pm_count.to_i >= 1
        puts "  ✓  kiosk.payment_mandates >= 1 (got #{pm_count})"
      else
        failures << "happy: kiosk.payment_mandates expected >= 1, got #{pm_count.inspect}"
        puts "  ✗  kiosk.payment_mandates expected >= 1, got #{pm_count.inspect}"
      end
    end

    # ── RUN 2: Negative gate — no payment ────────────────────────────────
    puts "\n══ Negative gate — SKIP_PAY ══"
    boot_server.call do
      env = {
        "SERVER_URL"       => server_url,
        "KIOSK_ISSUER"     => kiosk_issuer,
        "MASTER_KEY"       => master_key,
        "SKIP_PAY"         => "1",
      }
      env_str = env.map { |k, v| "#{k}=#{v}" }.join(" ")
      raw = `#{env_str} bundle exec ruby #{flow_rb} 2>&1`
      json_line = raw.lines.grep(/^\{/).last
      stderr_lines = raw.lines.reject { |l| l.start_with?("{") }
      puts stderr_lines.join
      puts json_line if json_line

      begin
        result = JSON.parse(json_line || raw)
      rescue JSON::ParserError => e
        abort "unlock_flow.rb (SKIP_PAY) did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
      end

      if result["http_unlock"] == 403
        puts "  ✓  SKIP_PAY: http_unlock == 403 (no MAC issued)"
      else
        failures << "skip_pay: http_unlock expected 403, got #{result["http_unlock"].inspect}"
        puts "  ✗  SKIP_PAY: http_unlock expected 403, got #{result["http_unlock"].inspect}"
      end
    end

    # ── RUN 3: Negative gate — no KYC ────────────────────────────────────
    puts "\n══ Negative gate — SKIP_KYC ══"
    boot_server.call do
      env = {
        "SERVER_URL"       => server_url,
        "KIOSK_ISSUER"     => kiosk_issuer,
        "MASTER_KEY"       => master_key,
        "SKIP_KYC"         => "1",
      }
      env_str = env.map { |k, v| "#{k}=#{v}" }.join(" ")
      raw = `#{env_str} bundle exec ruby #{flow_rb} 2>&1`
      json_line = raw.lines.grep(/^\{/).last
      stderr_lines = raw.lines.reject { |l| l.start_with?("{") }
      puts stderr_lines.join
      puts json_line if json_line

      begin
        result = JSON.parse(json_line || raw)
      rescue JSON::ParserError => e
        abort "unlock_flow.rb (SKIP_KYC) did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
      end

      if result["http_unlock"] == 403
        puts "  ✓  SKIP_KYC: http_unlock == 403 (no MAC issued)"
      else
        failures << "skip_kyc: http_unlock expected 403, got #{result["http_unlock"].inspect}"
        puts "  ✗  SKIP_KYC: http_unlock expected 403, got #{result["http_unlock"].inspect}"
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

desc "End-to-end Kiosk skooti demo: setup the DB then prove the full unlock chain."
task demo: ["demo:setup", "demo:rideflow"]
