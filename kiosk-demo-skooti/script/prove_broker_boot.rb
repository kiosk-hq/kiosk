# frozen_string_literal: true

require "net/http"
require "uri"

# ProveBrokerBoot — shared helper for skooti's two-server demo gates (demo:kyc
# and demo:redteam). The KYC broker (kyc.demo.kiosk.tech) is a SEPARATE Rails app
# (kiosk-demo-prove); these gates are now genuine two-server integrations. This
# helper boots the broker on its own port, sets up its DB, wires the intake
# allow-list to skooti's host, waits for readiness, and returns the env skooti
# (and the flow/redteam drivers) need to reach and trust the broker.
#
# Every trust anchor is wired EXPLICITLY here (K-650 — skooti no longer ships
# a pinned dev ProveKey): the broker's public key is fetched from the running
# broker's own GET /prove_key.pem and handed to skooti as
# KIOSK_PROVE_PUBLIC_KEY_PEM, alongside the URLs, the shared intake secret and
# the callback host.
#
# IT LIVES IN script/, NOT IN lib/, AND THAT IS THE BINDING CONDITION ON IT
# (K-663). This is CI/flow-driver harness code — it shells out, spawns a server
# and polls a port — and Phil's answer to the sibling-path question was one
# sentence: «Главное чтобы это не грузилось вместе с rails server'ом». In lib/
# it was inside the Rails autoload path and eager-loaded on every production
# boot of an app that never calls it. Now it is only ever reached by an explicit
# require from the demo rake tasks.
#
# AND THE LAYOUT ASSUMPTION IS DELIBERATE, NOT AN OVERSIGHT: BROKER_APP below
# resolves a SIBLING DIRECTORY of this demo, so it works in a checkout of this
# monorepo and nowhere else. That is accepted (K-663) because the demos are not
# packaged gems and nothing shipped depends on it — but an external reader
# should know it is here, and anyone moving a demo directory has to move this
# with it.
#
module ProveBrokerBoot
  BROKER_APP  = File.expand_path("../../kiosk-demo-prove", __dir__)
  BROKER_PORT = ENV.fetch("KIOSK_PROVE_PORT", "3020")
  SHARED_SECRET = "prove-skooti-demo-shared-secret"
  # The `iss` both apps must agree on. Pinned here explicitly on BOTH the broker
  # (it stamps this into every claim) and skooti (its KycVerifier compares the
  # minted `iss` against c.kyc_issuer). Kept as a local test identity so the gate
  # never depends on either app's deploy default; changing a default cannot
  # silently break the two-server gate.
  SHARED_ISSUER = "https://kyc.test.local"

  module_function

  # Boot the broker for the duration of the block. Yields a hash of the env vars
  # skooti + the drivers must carry:
  #   { broker_url:, wiring: {...} }
  # wiring is merged into skooti's server spawn AND the flow/redteam driver env.
  # (K-712k: this said `skooti_env:` / `driver_env:`, two keys the yield has
  # never produced. The getgrocery sibling has always documented it correctly.)
  #
  # @param skooti_host [String] the host skooti binds/serves on (for the broker's
  #   callback allow-list AND the callback_url skooti sends at intake).
  # @param log         [String] broker log path
  def with_broker(skooti_host:, log: "/tmp/kiosk-prove-broker.log")
    broker_host = "127.0.0.1"
    broker_url  = "http://#{broker_host}:#{BROKER_PORT}"

    # ── Set up the broker DB (idempotent) ──────────────────────────────────
    puts "\n── Setting up KYC broker DB (#{BROKER_APP}) ──"
    system(
      { "RAILS_ENV" => "development" },
      "bundle exec rails db:drop db:create db:schema:load db:seed",
      chdir: BROKER_APP,
    ) || abort("KYC broker DB setup failed")

    # ── Boot the broker ────────────────────────────────────────────────────
    File.truncate(log, 0) if File.exist?(log)
    broker_env = {
      "PORT"                            => BROKER_PORT,
      "RAILS_ENV"                       => "development",
      # SSRF allow-list: the ONLY host the broker will POST a callback to for
      # skooti is skooti's own host.
      "KIOSK_PROVE_SKOOTI_CALLBACK_HOST" => skooti_host,
      "KIOSK_PROVE_SKOOTI_SECRET"       => SHARED_SECRET,
      # The `iss` the broker stamps — pinned to match skooti's KIOSK_PROVE_ISSUER
      # below so the gate is independent of either app's deploy default.
      "KIOSK_PROVE_ISSUER"              => SHARED_ISSUER,
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

    # ── Wait for the broker to answer (and capture its public key) ─────────
    # The readiness probe doubles as the trust-anchor fetch: GET /prove_key.pem
    # returns the PUBLIC half of the key the running broker signs with, and
    # THAT is what skooti is told to trust — no pinned copy (K-650).
    prove_public_pem = nil
    40.times do
      begin
        res = Net::HTTP.get_response(URI("#{broker_url}/prove_key.pem"))
        if res.code.to_i == 200
          prove_public_pem = res.body
          break
        end
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
        nil
      end
      sleep 1
    end
    abort "KYC broker did not become ready — see #{log}" unless prove_public_pem
    puts "  KYC broker up at #{broker_url}"

    # The env skooti's server + the drivers must carry to reach/trust the broker.
    wiring = {
      "KIOSK_PROVE_BROKER_URL"    => broker_url,
      # Same `iss` the broker (broker_env above) stamps — skooti's KycVerifier
      # compares the minted `iss` against this, so both must line up.
      "KIOSK_PROVE_ISSUER"        => SHARED_ISSUER,
      # The operator side reads ONE role-named variable (K-694); the broker
      # side above reads its per-operator KIOSK_PROVE_SKOOTI_SECRET. Same
      # VALUE on both sides is what pairs them — the broker looks the operator
      # up by the operator_id in the intake body, not by a variable name.
      "KIOSK_PROVE_INTAKE_SECRET" => SHARED_SECRET,
      "KIOSK_PROVE_OPERATOR_ID"   => "skooti",
      # The running broker's OWN public key, fetched above (K-650).
      "KIOSK_PROVE_PUBLIC_KEY_PEM" => prove_public_pem,
    }

    begin
      yield({ broker_url: broker_url, wiring: wiring })
    ensure
      stop_broker.call
      puts "  KYC broker stopped."
    end
  end
end
