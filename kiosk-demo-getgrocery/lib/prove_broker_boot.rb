# frozen_string_literal: true

require "net/http"
require "uri"

# ProveBrokerBoot — shared helper for getgrocery's two-server age-gate gate
# (demo:agecheck). The KYC broker (kyc.demo.kiosk.tech) is a SEPARATE Rails app
# (kiosk-demo-prove); this gate is a genuine two-server integration. This helper
# boots the broker on its own port, sets up its DB, wires the intake allow-list
# to getgrocery's host (getgrocery is a SECOND registered operator alongside
# skooti), waits for readiness, and returns the env getgrocery (and the flow
# driver) need to reach and trust the broker.
#
# Every trust anchor is wired EXPLICITLY here (K-650 — getgrocery no longer
# ships a pinned dev ProveKey): the broker's public key is fetched from the
# running broker's own GET /prove_key.pem and handed to getgrocery as
# KIOSK_PROVE_PUBLIC_KEY_PEM, alongside the URLs, the shared intake secret and
# the callback host.
#
# DEPLOY FOLLOW-UP: getgrocery is allow-listed at the broker only by THIS test
# harness (via KIOSK_PROVE_GETGROCERY_* env). Registering getgrocery as a
# standing broker operator in the hosted deploy is a follow-up.
module ProveBrokerBoot
  BROKER_APP    = File.expand_path("../../kiosk-demo-prove", __dir__)
  # The broker's DEV/TEST signing key, pinned EXPLICITLY on the broker we boot
  # rather than left to its env file's default. Two reasons. (1) The pairing
  # stops being implicit: the driver's redteam beats need to mint a claim the
  # booted broker's key would have signed, and "both sides happen to fall back
  # to the same file" is not a pairing a reader can see. (2) The K-673 rule is
  # unchanged — this is the key whose private half ships in this public repo,
  # it is TEST scaffolding only, and the broker's production env file still
  # refuses to boot without a real PROVE_KEY_PEM and has no fallback.
  SIGNING_KEY_PATH = File.expand_path("../../kiosk-demo-prove/config/dev_prove_key.pem", __dir__)
  BROKER_PORT   = ENV.fetch("KIOSK_PROVE_PORT", "3020")
  SHARED_SECRET = "prove-getgrocery-demo-shared-secret"
  # The `iss` both apps must agree on. Pinned here explicitly on BOTH the broker
  # (it stamps this into every claim) and getgrocery (its KycVerifier compares
  # the minted `iss` against c.kyc_issuer). Kept as a local test identity so the
  # gate never depends on either app's deploy default.
  SHARED_ISSUER = "https://kyc.test.local"

  module_function

  # The PEM the booted broker signs with: an explicit PROVE_KEY_PEM if the
  # caller set one (driving a broker with a real key), else the repo's dev key.
  def signing_key
    from_env = ENV["PROVE_KEY_PEM"].to_s
    return from_env unless from_env.empty?

    File.read(SIGNING_KEY_PATH)
  end

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
    signing_key_pem = signing_key

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
      # Pinned, not defaulted — see SIGNING_KEY_PATH.
      "PROVE_KEY_PEM"                        => signing_key_pem,
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
    # THAT is what getgrocery is told to trust — no pinned copy (K-650).
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

    # The env getgrocery's server + the driver must carry to reach/trust the
    # broker.
    wiring = {
      "KIOSK_PROVE_BROKER_URL"        => broker_url,
      # Same `iss` the broker (broker_env above) stamps — getgrocery's
      # KycVerifier compares the minted `iss` against this, so both must line up.
      "KIOSK_PROVE_ISSUER"            => SHARED_ISSUER,
      # The operator side reads ONE role-named variable (K-694); the broker
      # side above reads its per-operator KIOSK_PROVE_GETGROCERY_SECRET. Same
      # VALUE on both sides is what pairs them — the broker looks the operator
      # up by the operator_id in the intake body, not by a variable name.
      "KIOSK_PROVE_INTAKE_SECRET"     => SHARED_SECRET,
      "KIOSK_PROVE_OPERATOR_ID"       => "getgrocery",
      # The running broker's OWN public key, fetched above (K-650).
      "KIOSK_PROVE_PUBLIC_KEY_PEM"    => prove_public_pem,
      # The PRIVATE half the broker was booted with, for the driver's redteam
      # beats only: they need attestations that are genuinely signed but
      # deliberately malformed in one respect (a non-canonical boolean
      # spelling, K-656), which the real broker will never mint. A beat that
      # signed with its own fresh key would only re-test the signature check
      # the R1 beat already covers.
      "KIOSK_PROVE_TEST_SIGNING_KEY_PEM" => signing_key_pem,
    }

    begin
      yield({ broker_url: broker_url, wiring: wiring })
    ensure
      stop_broker.call
      puts "  KYC broker stopped."
    end
  end
end
