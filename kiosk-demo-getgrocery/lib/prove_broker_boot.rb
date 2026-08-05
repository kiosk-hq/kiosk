# frozen_string_literal: true

require "net/http"
require "uri"

# ProveBrokerBoot — shared helper for getgrocery's two-server age-gate gate
# (demo:agecheck). The prove.my broker is a SEPARATE Rails app
# (kiosk-demo-prove); this gate is a genuine two-server integration. This helper
# boots the broker on its own port, sets up its DB, wires the intake allow-list
# to getgrocery's host (getgrocery is a SECOND registered operator alongside
# skooti), waits for readiness, and returns the env getgrocery (and the flow
# driver) need to reach and trust the broker.
#
# The trust anchors line up out of the box: getgrocery's ProveTrust pins the
# broker's fixed dev ProveKey public half, so only the URLs + the shared intake
# secret + the callback host need wiring here.
#
# DEPLOY FOLLOW-UP: getgrocery is allow-listed at the broker only by THIS test
# harness (via KIOSK_PROVE_GETGROCERY_* env). Registering getgrocery as a
# standing broker operator in the hosted deploy is a follow-up.
module ProveBrokerBoot
  BROKER_APP    = File.expand_path("../../kiosk-demo-prove", __dir__)
  BROKER_PORT   = ENV.fetch("KIOSK_PROVE_PORT", "3020")
  SHARED_SECRET = "prove-getgrocery-demo-shared-secret"
  # The `iss` both apps must agree on. Pinned here explicitly on BOTH the broker
  # (it stamps this into every claim) and getgrocery (its KycVerifier compares
  # the minted `iss` against c.kyc_issuer). Kept as a local test identity so the
  # gate never depends on either app's deploy default.
  SHARED_ISSUER = "https://kyc.test.local"

  module_function

  # Boot the broker for the duration of the block. Yields a hash of the env vars
  # getgrocery + the driver must carry:
  #   { broker_url:, wiring: {...} }
  # wiring is merged into getgrocery's server spawn AND the flow driver env.
  #
  # @param operator_host [String] the host getgrocery binds/serves on (for the
  #   broker's callback allow-list AND the callback_url getgrocery sends at
  #   intake).
  # @param log           [String] broker log path
  def with_broker(operator_host:, log: "/tmp/kiosk-prove-broker-getgrocery.log")
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
      "PORT"                                 => BROKER_PORT,
      "RAILS_ENV"                            => "development",
      # SSRF allow-list: the ONLY host the broker will POST a callback to for
      # getgrocery is getgrocery's own host.
      "KIOSK_PROVE_GETGROCERY_CALLBACK_HOST" => operator_host,
      "KIOSK_PROVE_GETGROCERY_SECRET"        => SHARED_SECRET,
      # The `iss` the broker stamps — pinned to match getgrocery's
      # KIOSK_PROVE_ISSUER below so the gate is independent of any deploy default.
      "KIOSK_PROVE_ISSUER"                   => SHARED_ISSUER,
      # The verification_url the broker hands back must point at the broker's
      # reachable origin (host:port), so the human/driver can approve on it.
      "PROVE_PUBLIC_URL"                     => broker_url,
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

    # The env getgrocery's server + the driver must carry to reach/trust the
    # broker.
    wiring = {
      "KIOSK_PROVE_BROKER_URL"        => broker_url,
      # Same `iss` the broker (broker_env above) stamps — getgrocery's
      # KycVerifier compares the minted `iss` against this, so both must line up.
      "KIOSK_PROVE_ISSUER"            => SHARED_ISSUER,
      "KIOSK_PROVE_GETGROCERY_SECRET" => SHARED_SECRET,
      "KIOSK_PROVE_OPERATOR_ID"       => "getgrocery",
    }

    begin
      yield({ broker_url: broker_url, wiring: wiring })
    ensure
      stop_broker.call
      puts "  prove.my broker stopped."
    end
  end
end
