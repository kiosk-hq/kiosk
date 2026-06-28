# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-getgrocery.
# Tasks:
#   rake demo:setup   idempotent db:drop / create / migrate / seed
#   rake demo:shop    boots the server, runs getgrocery_flow.rb, asserts happy path
#   rake demo         setup + shop (full end-to-end proof)

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

  desc "Boot the server, run getgrocery_flow.rb end-to-end (no-human happy path), assert."
  task :shop do
    require "resolv"
    require "net/http"
    require "uri"
    require "json"

    port         = ENV.fetch("PORT", "3005")
    log          = "/tmp/kiosk-getgrocery-demo.log"
    db           = "kiosk_getgrocery_development"
    flow_rb      = File.expand_path("../../getgrocery_flow.rb", __dir__)
    failures     = []

    # -- host resolution --
    host = begin
      addr = begin
        Resolv.getaddress("getgrocery.app")
      rescue Resolv::ResolvError
        ""
      end
      if addr == "127.0.0.1"
        "getgrocery.app"
      else
        puts "  (add to /etc/hosts: 127.0.0.1 getgrocery.app -- using 127.0.0.1)" if addr.empty?
        "127.0.0.1"
      end
    end

    server_url   = "http://#{host}:#{port}"
    kiosk_issuer = server_url

    puts "\n-- Starting getgrocery on #{server_url} --"

    # -- boot the server --
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

    # -- wait for readiness --
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
    abort "Server did not become ready -- see #{log}" unless ready
    puts "  Server up at #{server_url}"

    # -- run getgrocery_flow.rb --
    puts "\n-- Running getgrocery_flow.rb --"
    env_str = "SERVER_URL=#{server_url} KIOSK_ISSUER=#{kiosk_issuer}"
    raw     = `#{env_str} bundle exec ruby #{flow_rb.shellescape} 2>&1`
    puts raw

    begin
      result = JSON.parse(raw.lines.grep(/^\{/).last || raw)
    rescue JSON::ParserError => e
      abort "getgrocery_flow.rb did not produce valid JSON: #{e.message}\nOutput:\n#{raw}"
    end

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

    check.call("http_register",         result["http_register"],         201)
    check.call("http_stores",           result["http_stores"],           200)
    check.call("http_products",         result["http_products"],         200)
    check.call("http_add_to_cart",      result["http_add_to_cart"],      200)
    check.call("http_add_oos",          result["http_add_oos"],          200)
    check.call("http_sub_options",      result["http_sub_options"],      200)
    check.call("http_apply_sub",        result["http_apply_sub"],        200)
    check.call("http_delivery_slots",   result["http_delivery_slots"],   200)
    check.call("http_confirm_delivery", result["http_confirm_delivery"], 200)
    check.call("http_pay",              result["http_pay"],              200)

    # Delivery ID present
    did = result["delivery_id"]
    if did && !did.to_s.empty?
      puts "  OK  delivery_id present (#{did})"
    else
      failures << "delivery_id missing or empty"
      puts "  FAIL  delivery_id missing or empty"
    end

    # Scheduled_at present
    sat = result["scheduled_at"]
    if sat && !sat.to_s.empty?
      puts "  OK  scheduled_at present (#{sat})"
    else
      failures << "scheduled_at missing or empty"
      puts "  FAIL  scheduled_at missing or empty"
    end

    # Substitution accepted
    if result["substitution_accepted"] == true
      puts "  OK  substitution_accepted == true"
    else
      failures << "substitution_accepted expected true, got #{result["substitution_accepted"].inspect}"
      puts "  FAIL  substitution_accepted expected true, got #{result["substitution_accepted"].inspect}"
    end

    # pay.ok == true
    pay = result["pay"] || {}
    if pay["ok"] == true
      puts "  OK  pay.ok == true"
    else
      failures << "pay.ok not true (got #{pay["ok"].inspect})"
      puts "  FAIL  pay.ok got #{pay["ok"].inspect}"
    end

    pm_id = pay.dig("value", "payment_mandate_id")
    if pm_id && !pm_id.to_s.empty?
      puts "  OK  pay.value.payment_mandate_id present (#{pm_id})"
    else
      failures << "pay.value.payment_mandate_id missing"
      puts "  FAIL  pay.value.payment_mandate_id missing"
    end

    # -- assertions: DB row counts --
    deliveries_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM deliveries' 2>&1`.strip
    if deliveries_count.to_i >= 1
      puts "  OK  deliveries count >= 1 (got #{deliveries_count})"
    else
      failures << "deliveries COUNT expected >= 1, got #{deliveries_count.inspect}"
      puts "  FAIL  deliveries COUNT expected >= 1, got #{deliveries_count.inspect}"
    end

    pm_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM kiosk.payment_mandates' 2>&1`.strip
    if pm_count.to_i >= 1
      puts "  OK  kiosk.payment_mandates >= 1 (got #{pm_count})"
    else
      failures << "kiosk.payment_mandates COUNT expected >= 1, got #{pm_count.inspect}"
      puts "  FAIL  kiosk.payment_mandates COUNT expected >= 1, got #{pm_count.inspect}"
    end

    # Substituted cart_item in DB
    sub_count = `psql -X -d #{db} -tAc 'SELECT COUNT(*) FROM cart_items WHERE substituted = true' 2>&1`.strip
    if sub_count.to_i >= 1
      puts "  OK  cart_items[substituted=true] >= 1 (got #{sub_count})"
    else
      failures << "cart_items[substituted=true] expected >= 1, got #{sub_count.inspect}"
      puts "  FAIL  cart_items[substituted=true] expected >= 1, got #{sub_count.inspect}"
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
end

desc "End-to-end getgrocery demo: setup DB then run no-human cart->substitution->delivery."
task demo: ["demo:setup", "demo:shop"]
