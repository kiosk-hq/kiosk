# frozen_string_literal: true

require "net/http"
require "uri"

# ProveBrokerBoot — shared helper for skooti's two-server demo gates (demo:kyc
# and demo:redteam). The prove.my broker is a SEPARATE Rails app
# (kiosk-demo-prove); these gates are now genuine two-server integrations. This
# helper boots the broker on its own port, sets up its DB, wires the intake
# allow-list to skooti's host, waits for readiness, and returns the env skooti
# (and the flow/redteam drivers) need to reach and trust the broker.
#
# The trust anchors line up out of the box: skooti's ProveTrust pins the broker's
# fixed dev ProveKey public half and defaults its issuer to "https://prove.my"
# (== the broker's ProveKey::ISSUER), so only the URLs + the shared intake secret
# + the callback host need wiring here.
module ProveBrokerBoot
  BROKER_APP  = File.expand_path("../../kiosk-demo-prove", __dir__)
  BROKER_PORT = ENV.fetch("KIOSK_PROVE_PORT", "3020")
  SHARED_SECRET = "prove-skooti-demo-shared-secret"

  module_function

  # Boot the broker for the duration of the block. Yields a hash of the env vars
  # skooti + the drivers must carry:
  #   { broker_url:, skooti_env: {...}, driver_env: {...} }
  # skooti_env is merged into skooti's server spawn; driver_env into the
  # flow/redteam driver subprocess.
  #
  # @param skooti_host [String] the host skooti binds/serves on (for the broker's
  #   callback allow-list AND the callback_url skooti sends at intake).
  # @param log         [String] broker log path
  def with_broker(skooti_host:, log: "/tmp/kiosk-prove-broker.log")
    broker_host = "127.0.0.1"
    broker_url  = "http://#{broker_host}:#{BROKER_PORT}"

    # ── Set up the broker DB (idempotent) ──────────────────────────────────
    puts "\n── Setting up prove.my broker DB (#{BROKER_APP}) ──"
    system(
      { "RAILS_ENV" => "development" },
      "bundle exec rails db:drop db:create db:schema:load db:seed",
      chdir: BROKER_APP,
    ) || abort("prove.my broker DB setup failed")

    # ── Boot the broker ────────────────────────────────────────────────────
    File.truncate(log, 0) if File.exist?(log)
    broker_env = {
      "PORT"                            => BROKER_PORT,
      "RAILS_ENV"                       => "development",
      # SSRF allow-list: the ONLY host the broker will POST a callback to for
      # skooti is skooti's own host.
      "KIOSK_PROVE_SKOOTI_CALLBACK_HOST" => skooti_host,
      "KIOSK_PROVE_SKOOTI_SECRET"       => SHARED_SECRET,
      # The verification_url the broker hands back must point at the broker's
      # reachable origin (host:port), so the human/driver can approve on it.
      "PROVE_PUBLIC_URL"                => broker_url,
    }
    broker_pid = spawn(
      broker_env,
      "bundle exec rails s -p #{BROKER_PORT} -b #{broker_host} -e development",
      chdir: BROKER_APP, out: log, err: log,
    )

    stop_broker = lambda do
      begin
        Process.kill("TERM", broker_pid)
        Process.wait(broker_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    at_exit { stop_broker.call }

    # ── Wait for the broker to answer ──────────────────────────────────────
    ready = false
    40.times do
      begin
        res = Net::HTTP.get_response(URI("#{broker_url}/prove_key.pem"))
        if res.code.to_i == 200
          ready = true
          break
        end
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
        nil
      end
      sleep 1
    end
    abort "prove.my broker did not become ready — see #{log}" unless ready
    puts "  prove.my broker up at #{broker_url}"

    # The env skooti's server + the drivers must carry to reach/trust the broker.
    wiring = {
      "KIOSK_PROVE_BROKER_URL"    => broker_url,
      "KIOSK_PROVE_ISSUER"        => "https://prove.my",
      "KIOSK_PROVE_SKOOTI_SECRET" => SHARED_SECRET,
      "KIOSK_PROVE_OPERATOR_ID"   => "skooti",
    }

    begin
      yield({ broker_url: broker_url, wiring: wiring })
    ensure
      stop_broker.call
      puts "  prove.my broker stopped."
    end
  end
end
