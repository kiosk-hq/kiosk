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
# Every trust anchor is wired EXPLICITLY here, and getgrocery ships no pinned
# dev ProveKey: the broker's public key is fetched from the running broker's
# own GET /prove_key.pem and handed to getgrocery as
# KIOSK_PROVE_PUBLIC_KEY_PEM, alongside the URLs, the shared intake secret and
# the callback host.
#
# DEPLOY FOLLOW-UP: getgrocery is allow-listed at the broker only by THIS test
# harness (via KIOSK_PROVE_GETGROCERY_* env). Registering getgrocery as a
# standing broker operator in the hosted deploy is a follow-up.
#
# THE FILE IS SPLIT THE WAY IT IS SO A GATE CAN HOLD THE SHARED HALF. skooti
# ships the same helper, and {with_broker} is ~55 of its ~64 normalised lines
# identical between the two copies — the DB setup, the spawn, the at_exit stop,
# the 40-second readiness poll and the yield/ensure — while the few lines that
# genuinely differ are all OPERATOR IDENTITY. Declared whole it would have to be
# `:per_demo`, which bin/check-demo-copies defines as compared to NOTHING, so an
# edit to the poll or the teardown reaching one copy would be invisible. The
# operator half lives in {broker_operator_env}, {operator_wiring},
# {broker_signing_key_pem} and BROKER_LOG — four small per-demo units — and
# {with_broker} itself is held `:code` against skooti's copy.
#
# IT LIVES IN script/, NOT IN lib/, AND THAT IS THE BINDING CONDITION ON IT.
# This is CI/flow-driver harness code — it shells out, spawns a server and
# polls a port — and the binding rule on it is that it must never be loaded
# alongside `rails server`. In lib/ it would sit inside the Rails autoload
# path and be eager-loaded on every production boot of an app that never
# calls it. Here it is only ever reached by an explicit require from the demo
# rake tasks.
#
# AND THE LAYOUT ASSUMPTION IS DELIBERATE, NOT AN OVERSIGHT: BROKER_APP below
# resolves a SIBLING DIRECTORY of this demo, so it works in a checkout of this
# monorepo and nowhere else. That is accepted because the demos are not
# packaged gems and nothing shipped depends on it — but an external reader
# should know it is here, and anyone moving a demo directory has to move this
# with it.
#
module ProveBrokerBoot
  BROKER_APP    = File.expand_path("../../kiosk-demo-prove", __dir__)
  # The broker's DEV/TEST signing key, pinned EXPLICITLY on the broker we boot
  # rather than left to its env file's default. Two reasons. (1) The pairing
  # stops being implicit: the driver's redteam beats need to mint a claim the
  # booted broker's key would have signed, and "both sides happen to fall back
  # to the same file" is not a pairing a reader can see. (2) The rule on this
  # key is unchanged — its private half ships in this public repo,
  # it is TEST scaffolding only, and the broker's production env file still
  # refuses to boot without a real PROVE_KEY_PEM and has no fallback.
  SIGNING_KEY_PATH = File.expand_path("../../kiosk-demo-prove/config/dev_prove_key.pem", __dir__)
  BROKER_PORT   = ENV.fetch("KIOSK_PROVE_PORT", "3020")
  SHARED_SECRET = "prove-getgrocery-demo-shared-secret"
  # Where the booted broker's log lands by default. Per-operator on purpose: the
  # two KYC demos boot the same broker app, and a shared default would have one
  # demo's run truncate the log the other is being debugged from.
  BROKER_LOG    = "/tmp/kiosk-prove-broker-getgrocery.log"
  # The `iss` both apps must agree on. Pinned here explicitly on BOTH the broker
  # (it stamps this into every claim) and getgrocery (its KycVerifier compares
  # the minted `iss` against c.kyc_issuer). Kept as a local test identity so the
  # gate never depends on either app's deploy default.
  SHARED_ISSUER = "https://kyc.test.local"

  module_function

  # The PEM the booted broker signs with: an explicit PROVE_KEY_PEM if the
  # caller set one (driving a broker with a real key), else the repo's dev key.
  #
  # PER-OPERATOR: getgrocery PINS the key, because its redteam beats
  # need the private half to mint deliberately-malformed but genuinely signed
  # attestations. skooti's copy returns nil and lets the broker fall back to its
  # own env default — so this is a real divergence, not drift.
  def broker_signing_key_pem
    from_env = ENV["PROVE_KEY_PEM"].to_s
    return from_env unless from_env.empty?

    File.read(SIGNING_KEY_PATH)
  end

  # PER-OPERATOR: the slice of the BROKER's env that names THIS
  # operator. The broker keys its SSRF callback allow-list and its intake secret
  # by operator name, so these variable NAMES cannot be shared with skooti's
  # copy — which is precisely why they are here and not in {with_broker}.
  #
  # @param operator_host    [String] the host getgrocery serves on
  # @param signing_key_pem  [String] see {broker_signing_key_pem}
  def broker_operator_env(operator_host, signing_key_pem)
    {
      # SSRF allow-list: the ONLY host the broker will POST a callback to for
      # getgrocery is getgrocery's own host.
      "KIOSK_PROVE_GETGROCERY_CALLBACK_HOST" => operator_host,
      "KIOSK_PROVE_GETGROCERY_SECRET"        => SHARED_SECRET,
      # Pinned, not defaulted — see SIGNING_KEY_PATH.
      "PROVE_KEY_PEM"                        => signing_key_pem,
    }
  end

  # PER-OPERATOR: the env getgrocery's server + the driver must carry to
  # reach and trust the broker. It names getgrocery as the operator and carries
  # the redteam signing key, neither of which skooti's copy does.
  #
  # @param broker_url       [String] the booted broker's reachable origin
  # @param prove_public_pem [String] the running broker's own public key
  # @param signing_key_pem  [String] see {broker_signing_key_pem}
  def operator_wiring(broker_url, prove_public_pem, signing_key_pem)
    {
      "KIOSK_PROVE_BROKER_URL"        => broker_url,
      # Same `iss` the broker (broker_env in {with_broker}) stamps — getgrocery's
      # KycVerifier compares the minted `iss` against this, so both must line up.
      "KIOSK_PROVE_ISSUER"            => SHARED_ISSUER,
      # The operator side reads ONE role-named variable; the broker
      # side reads its per-operator KIOSK_PROVE_GETGROCERY_SECRET. Same
      # VALUE on both sides is what pairs them — the broker looks the operator
      # up by the operator_id in the intake body, not by a variable name.
      "KIOSK_PROVE_INTAKE_SECRET"     => SHARED_SECRET,
      "KIOSK_PROVE_OPERATOR_ID"       => "getgrocery",
      # The running broker's OWN public key, fetched in {with_broker}.
      "KIOSK_PROVE_PUBLIC_KEY_PEM"    => prove_public_pem,
      # The PRIVATE half the broker was booted with, for the driver's redteam
      # beats only: they need attestations that are genuinely signed but
      # deliberately malformed in one respect (a non-canonical boolean
      # spelling), which the real broker will never mint. A beat that
      # signed with its own fresh key would only re-test the signature check
      # the R1 beat already covers.
      "KIOSK_PROVE_TEST_SIGNING_KEY_PEM" => signing_key_pem,
    }
  end

  # Boot the broker for the duration of the block. Yields a hash of the env vars
  # getgrocery + the driver must carry:
  #   { broker_url:, wiring: {...} }
  # wiring is merged into getgrocery's server spawn AND the flow driver env.
  #
  # SHARED WITH skooti AND HELD THERE: everything below is operator-
  # neutral and bin/check-demo-copies compares it against skooti's copy modulo
  # comments. Anything that has to name this operator belongs in one of the
  # three per-demo methods above, not here.
  #
  # @param operator_host [String] the host getgrocery binds/serves on (for the
  #   broker's callback allow-list AND the callback_url getgrocery sends at
  #   intake).
  # @param log           [String] broker log path
  def with_broker(operator_host:, log: BROKER_LOG)
    broker_host = "127.0.0.1"
    broker_url  = "http://#{broker_host}:#{BROKER_PORT}"
    signing_key_pem = broker_signing_key_pem

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
      "PORT"               => BROKER_PORT,
      "RAILS_ENV"          => "development",
      # The `iss` the broker stamps — pinned to match the operator's
      # KIOSK_PROVE_ISSUER so the gate is independent of any deploy default.
      "KIOSK_PROVE_ISSUER" => SHARED_ISSUER,
      # The verification_url the broker hands back must point at the broker's
      # reachable origin (host:port), so the human/driver can approve on it.
      "PROVE_PUBLIC_URL"   => broker_url,
    }.merge(broker_operator_env(operator_host, signing_key_pem))
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
    # THAT is what the operator is told to trust — no pinned copy.
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

    wiring = operator_wiring(broker_url, prove_public_pem, signing_key_pem)

    begin
      yield({ broker_url: broker_url, wiring: wiring })
    ensure
      stop_broker.call
      puts "  KYC broker stopped."
    end
  end
end
