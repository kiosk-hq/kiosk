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
# THE FILE IS SPLIT THE WAY IT IS SO A GATE CAN HOLD THE SHARED HALF (T-147).
# getgrocery ships the same helper, and {with_broker} was ~55 of its ~64
# normalised lines identical between the two copies — the DB setup, the spawn,
# the at_exit stop, the 40-second readiness poll and the yield/ensure — while
# the four lines that genuinely differ are all OPERATOR IDENTITY. Declared whole
# it had to be `:per_demo`, which bin/check-demo-copies defines as compared to
# NOTHING, so an edit to the poll or the teardown reaching one copy was
# invisible. The operator half now lives in {broker_operator_env},
# {operator_wiring}, {broker_signing_key_pem} and BROKER_LOG — four small
# per-demo units — and {with_broker} itself is held `:code` against
# getgrocery's copy.
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
  # Where the booted broker's log lands by default. Per-operator on purpose: the
  # two KYC demos boot the same broker app, and a shared default would have one
  # demo's run truncate the log the other is being debugged from.
  BROKER_LOG  = "/tmp/kiosk-prove-broker.log"
  # The `iss` both apps must agree on. Pinned here explicitly on BOTH the broker
  # (it stamps this into every claim) and skooti (its KycVerifier compares the
  # minted `iss` against c.kyc_issuer). Kept as a local test identity so the gate
  # never depends on either app's deploy default; changing a default cannot
  # silently break the two-server gate.
  SHARED_ISSUER = "https://kyc.test.local"

  module_function

  # PER-OPERATOR (T-147): the PEM the booted broker signs with. skooti pins
  # NOTHING and returns nil, so the broker falls back to the key its own
  # development env file configures. getgrocery's copy DOES pin one, because its
  # redteam beats need the private half to mint deliberately-malformed but
  # genuinely signed attestations; skooti's redteam beats do not.
  def broker_signing_key_pem
    nil
  end

  # PER-OPERATOR (T-147): the slice of the BROKER's env that names THIS
  # operator. The broker keys its SSRF callback allow-list and its intake secret
  # by operator name, so these variable NAMES cannot be shared with getgrocery's
  # copy — which is precisely why they are here and not in {with_broker}.
  #
  # @param operator_host    [String] the host skooti serves on
  # @param _signing_key_pem [String, nil] see {broker_signing_key_pem}; skooti
  #   pins no key, so it is not passed on to the broker.
  def broker_operator_env(operator_host, _signing_key_pem)
    {
      # SSRF allow-list: the ONLY host the broker will POST a callback to for
      # skooti is skooti's own host.
      "KIOSK_PROVE_SKOOTI_CALLBACK_HOST" => operator_host,
      "KIOSK_PROVE_SKOOTI_SECRET"        => SHARED_SECRET,
    }
  end

  # PER-OPERATOR (T-147): the env skooti's server + the drivers must carry to
  # reach and trust the broker. It names skooti as the operator and carries no
  # redteam signing key, neither of which matches getgrocery's copy.
  #
  # @param broker_url       [String] the booted broker's reachable origin
  # @param prove_public_pem [String] the running broker's own public key
  # @param _signing_key_pem [String, nil] see {broker_signing_key_pem}; skooti
  #   ships no redteam beat that needs the private half.
  def operator_wiring(broker_url, prove_public_pem, _signing_key_pem)
    {
      "KIOSK_PROVE_BROKER_URL"    => broker_url,
      # Same `iss` the broker (broker_env in {with_broker}) stamps — skooti's
      # KycVerifier compares the minted `iss` against this, so both must line up.
      "KIOSK_PROVE_ISSUER"        => SHARED_ISSUER,
      # The operator side reads ONE role-named variable (K-694); the broker
      # side reads its per-operator KIOSK_PROVE_SKOOTI_SECRET. Same
      # VALUE on both sides is what pairs them — the broker looks the operator
      # up by the operator_id in the intake body, not by a variable name.
      "KIOSK_PROVE_INTAKE_SECRET" => SHARED_SECRET,
      "KIOSK_PROVE_OPERATOR_ID"   => "skooti",
      # The running broker's OWN public key, fetched in {with_broker} (K-650).
      "KIOSK_PROVE_PUBLIC_KEY_PEM" => prove_public_pem,
    }
  end

  # Boot the broker for the duration of the block. Yields a hash of the env vars
  # skooti + the drivers must carry:
  #   { broker_url:, wiring: {...} }
  # wiring is merged into skooti's server spawn AND the flow/redteam driver env.
  # (K-712k: this said `skooti_env:` / `driver_env:`, two keys the yield has
  # never produced. The getgrocery sibling has always documented it correctly.)
  #
  # SHARED WITH getgrocery AND HELD THERE (T-147): everything below is operator-
  # neutral and bin/check-demo-copies compares it against getgrocery's copy
  # modulo comments. Anything that has to name this operator belongs in one of
  # the three per-demo methods above, not here. The keyword is `operator_host:`
  # rather than the `skooti_host:` it used to be for the same reason — a
  # per-operator NAME in a shared signature is what forced the whole method to
  # be declared per-demo.
  #
  # @param operator_host [String] the host skooti binds/serves on (for the
  #   broker's callback allow-list AND the callback_url skooti sends at intake).
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
    # THAT is what the operator is told to trust — no pinned copy (K-650).
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
