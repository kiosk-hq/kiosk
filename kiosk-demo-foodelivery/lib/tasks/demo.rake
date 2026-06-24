# frozen_string_literal: true

# Kiosk demo orchestration. Tasks:
#
#   rake demo:setup        idempotent db:drop / create / migrate / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase, tears down
#   rake demo:order        boots the server, runs order_flow.rb (no-human full order),
#                          asserts DB row counts, tears down
#   rake demo              setup + order (the full end-to-end proof)
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

  desc "Boot the server and run the curl demo walkthrough."
  task :walkthrough do
    exec File.expand_path("../../bin/demo", __dir__)
  end

  desc "Boot the server, run the no-human order_flow.rb end-to-end, assert DB rows."
  task :order do
    require "resolv"

    port = ENV.fetch("PORT", "3002")
    log  = "/tmp/kiosk-foodelivery-demo.log"

    # ── host resolution ────────────────────────────────────────────────
    host = begin
      addr = Resolv.getaddress("foodelivery.app") rescue ""
      if addr == "127.0.0.1"
        "foodelivery.app"
      else
        puts "  add to /etc/hosts:  127.0.0.1 foodelivery.app" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n── Starting foodelivery on #{server_url} ──"

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

    # ── run order_flow.rb ──────────────────────────────────────────────
    flow_rb = File.expand_path("../../order_flow.rb", __dir__)
    puts "\n── Running order_flow.rb ──"
    raw = `SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer} bundle exec ruby #{flow_rb} 2>&1`
    puts raw

    # ── parse JSON output ──────────────────────────────────────────────
    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "order_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

    # ── assertions: HTTP + JSON ────────────────────────────────────────
    puts "\n── Assertions ──"
    failures = []

    pay   = result["pay"]   || {}
    order = result["order"] || {}

    if pay["ok"] == true
      puts "  ✓  pay.ok == true"
    else
      failures << "pay.ok is not true (got #{pay["ok"].inspect})"
      puts "  ✗  pay.ok — got #{pay["ok"].inspect}"
    end

    pm_id = pay.dig("value", "payment_mandate_id")
    if pm_id && !pm_id.empty?
      puts "  ✓  pay.value.payment_mandate_id present (#{pm_id})"
    else
      failures << "pay.value.payment_mandate_id missing"
      puts "  ✗  pay.value.payment_mandate_id missing"
    end

    oid = order["order_id"]
    if oid && !oid.empty?
      puts "  ✓  order.order_id present (#{oid})"
    else
      failures << "order.order_id missing"
      puts "  ✗  order.order_id missing"
    end

    # ── assertions: psql row counts ────────────────────────────────────
    db = "kiosk_foodelivery_development"

    orders_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM orders' 2>&1`.strip
    if orders_count == "1"
      puts "  ✓  orders count = 1"
    else
      failures << "orders COUNT expected 1, got #{orders_count.inspect}"
      puts "  ✗  orders COUNT expected 1, got #{orders_count.inspect}"
    end

    pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates' 2>&1`.strip
    if pm_count == "1"
      puts "  ✓  kiosk.payment_mandates count = 1"
    else
      failures << "kiosk.payment_mandates COUNT expected 1, got #{pm_count.inspect}"
      puts "  ✗  kiosk.payment_mandates COUNT expected 1, got #{pm_count.inspect}"
    end

    if failures.empty?
      puts "\n  All assertions passed."
    else
      puts "\n  FAILED assertions:"
      failures.each { |f| puts "    - #{f}" }
      exit 1
    end
  end
end

desc "End-to-end Kiosk demo: setup the DB then run the no-human order end-to-end."
task demo: ["demo:setup", "demo:order"]
