# frozen_string_literal: true

require "openssl"
require "jwt"

# ProveTestIssuer — a TEST-ONLY signer that mints attestations with the broker's
# ProveKey PRIVATE key, for skooti's flow/redteam/isolation scaffolding that
# needs a VALID (or expired) attestation for a given user_id WITHOUT driving the
# full broker HTTP round-trip (e.g. "KYC a fresh agent so only the gate under
# test can block"). It is the direct analogue of the retired StubKyc.attest —
# but now signing with the SHARED broker key skooti trusts (the KYC rake tasks
# pin c.kyc_public_key to ProveTestIssuer.public_key_pem — the ProveKey public
# half — via KIOSK_PROVE_PUBLIC_KEY_PEM on the server they spawn; K-650).
#
# WHY IT NO LONGER LOADS THE BROKER'S ProveKey (K-681). This file used to
# `require` the sibling app's kiosk-demo-prove/lib/prove_key.rb across the app
# boundary, back when that module was a self-contained constant carrier. K-672
# moved the broker's key and issuer into the broker's OWN per-environment Rails
# config (Rails.configuration.x.prove), which turned that cross-app require into
# a file that only works inside the BOOTED BROKER — while this file is loaded
# into two FOREIGN processes, and broke in both:
#   * skooti's own Rails (demo:rideflow, demo:isolation, the KYC rake tasks):
#     `Rails` resolves, but skooti's config has no `x.prove` block (skooti sets
#     x.kiosk.prove_*), so key_pem came back nil and OpenSSL::PKey::RSA.new(nil)
#     raised TypeError — no NameError to point at the cause;
#   * the bare-Ruby drivers (script/redteam_suite.rb, script/isolation_flow.rb):
#     no Rails at all → NameError: uninitialized constant ProveKey::Rails.
# So the test issuer now resolves its own key and issuer and does not touch the
# broker's app load path at all — the same principle as ProveTrust below
# (flow-only helpers stay off a Rails app's load path; K-659/K-663).
#
# HOW THE TWO STAY IN LOCKSTEP. They must sign with the SAME key and stamp the
# SAME `iss`, or every valid-attestation control in the drivers is rejected:
#   key — both read the SAME FILE: kiosk-demo-prove/config/dev_prove_key.pem,
#         where K-673 put the dev/test key, and which the broker's development
#         and test env files read by that exact path. PROVE_KEY_PEM overrides on
#         both sides, in the same precedence order.
#   iss — ProveTrust.issuer is literally the same expression the broker's env
#         files use (KIOSK_PROVE_ISSUER, defaulting to the deploy origin), and
#         the two-server harness pins KIOSK_PROVE_ISSUER on BOTH sides.
#   And the lockstep is CHECKED, not merely documented: the two-server
#   demo:redteam gate calls .assert_matches_broker! with the public key the
#   RUNNING broker serves at GET /prove_key.pem, so a broker that changes its
#   key source reddens that gate with a message naming this file.
#
# WHY THIS CANNOT REOPEN K-673 (production must never sign KYC claims with the
# dev key that ships in this public repo). This file lives in kiosk-demo-skooti
# and is loaded ONLY by skooti's flow/redteam/rake scaffolding — the served
# broker never loads it, and the broker's own resolution is untouched: ProveKey
# still reads Rails.configuration.x.prove.key_pem and production's env file
# still refuses to boot without PROVE_KEY_PEM, with no fallback anywhere. Belt
# and braces, the dev-key fallback HERE also refuses to arm when RAILS_ENV /
# RACK_ENV says production, so not even a hand-run driver can mint claims with
# the world-readable key under a production env.
#
# It signs a minimal claim carrying just what KycVerifier checks
# (sub/iss/level/exp) plus the anonymized attributes; the operator/nonce/
# request_id fields the async callback path uses are irrelevant here (this
# bypasses the callback).
#
#   ProveTestIssuer.attest(user_id:, attributes:) → compact RS256 JWS
#   ProveTestIssuer.attest_expired(user_id:)       → same, but exp 1h in the past
module ProveTestIssuer
  # The broker's dev/test signing key — the SAME file kiosk-demo-prove's
  # config/environments/{development,test}.rb read (K-673 moved the PEM out of
  # code into this file). Path is relative to this file so it resolves whether
  # required from a flow, the redteam, or a rake task. Only the key MATERIAL
  # crosses the app boundary now, never the broker's Rails-bound code (K-681).
  DEV_KEY_PATH = File.expand_path("../../kiosk-demo-prove/config/dev_prove_key.pem", __dir__)

  module_function

  # The PEM this issuer signs with, resolved exactly as the broker's dev/test
  # env files resolve theirs: PROVE_KEY_PEM when set, else the baked dev key.
  # A driver hand-run against a broker booted with an explicit PROVE_KEY_PEM
  # therefore still signs with the key that broker trusts.
  def key_pem
    from_env = ENV["PROVE_KEY_PEM"].to_s
    return from_env unless from_env.empty?

    if ENV.fetch("RAILS_ENV") { ENV["RACK_ENV"] }.to_s == "production"
      raise <<~MSG
        ProveTestIssuer refuses to mint with the baked dev key under a
        production environment (K-673/K-681).

        #{DEV_KEY_PATH} is the broker's DEV/TEST key and its private half
        ships in this public repo — anything it signs is forgeable by anyone
        with a clone. This is TEST scaffolding for the flow/redteam drivers;
        it has no production role. If you really are driving a production
        broker, export the key that broker signs with:

          PROVE_KEY_PEM=$(cat your-real-key.pem)
      MSG
    end

    File.read(DEV_KEY_PATH)
  end

  def keypair
    @keypair ||= OpenSSL::PKey::RSA.new(key_pem)
  end

  # The `iss` the minted claims carry — ProveTrust.issuer, the same
  # KIOSK_PROVE_ISSUER value (and the same default) the broker stamps and
  # skooti's KycVerifier compares against, pinned on both sides by the
  # two-server harness.
  def issuer
    prove_trust.issuer
  end

  # The ProveKey PUBLIC half, PEM-encoded. The single-server KYC rake tasks
  # (rideflow, isolation) pin this on the server they spawn as
  # KIOSK_PROVE_PUBLIC_KEY_PEM, so the server trusts exactly the key this
  # test issuer signs with — there is no pinned fallback in the app (K-650).
  def public_key_pem
    keypair.public_key.to_pem
  end

  # The two-server drift alarm (K-681). The two-server gates trust the key the
  # RUNNING broker serves at GET /prove_key.pem, while the drivers' valid-KYC
  # controls are minted here — the two are kept in lockstep by both sides
  # reading kiosk-demo-prove/config/dev_prove_key.pem, which nothing enforces
  # by itself. Called with the broker's fetched public PEM, this turns a silent
  # divergence (every valid attestation rejected as a forgery, reported as an
  # unrelated scenario failure) into one message that names the cause.
  def assert_matches_broker!(broker_public_pem)
    return true if public_key_pem.to_s.strip == broker_public_pem.to_s.strip

    abort <<~MSG
      ProveKey drift: the running KYC broker signs with a DIFFERENT key than
      ProveTestIssuer mints with, so every valid-attestation control in the
      drivers would be rejected as a forgery.

      ProveTestIssuer reads #{DEV_KEY_PATH} (or PROVE_KEY_PEM); the broker
      resolves its key in kiosk-demo-prove/config/environments/*.rb. Those two
      must name the same key — see the lockstep note in
      kiosk-demo-skooti/script/prove_test_issuer.rb (K-681).
    MSG
  end

  # The operator-binding audience the minted claims carry as `aud`. Sourced from
  # ProveTrust.operator_id — the SAME value skooti sets as c.kyc_audience — so the
  # engine's operator-binding check passes on the test-issuer path exactly as on
  # the real broker path. Read from ProveTrust (not Kiosk.configuration) because
  # the flow/redteam drivers run as STANDALONE scripts (no Kiosk config booted),
  # while ProveTrust is a plain module both the drivers and the server load.
  def audience
    prove_trust.operator_id
  end

  # ProveTrust, loaded by absolute path: this file is required from drivers, from
  # rake tasks and from the app, so a bare `require "prove_trust"` would depend
  # on whose $LOAD_PATH is in play.
  def prove_trust
    require File.expand_path("../app/services/prove_trust", __dir__) unless defined?(::ProveTrust)
    ::ProveTrust
  end

  # Mint a valid attestation bound to user_id, optionally carrying anonymized
  # boolean attributes. Signed with the ProveKey — the key skooti trusts. Carries
  # `aud` = skooti's kyc_audience so the engine's operator-binding check passes.
  def attest(user_id:, attributes: nil)
    now = Time.now.to_i
    payload = { sub: user_id.to_s, level: "verified", iss: issuer, aud: audience, iat: now, exp: now + 3600 }
    payload[:attributes] = attributes unless attributes.nil?
    JWT.encode(payload, keypair, "RS256")
  end

  # Mint an attestation signed with the real ProveKey but exp 1h in the past —
  # exercises the operator's exp check specifically (not just signature).
  def attest_expired(user_id:)
    now = Time.now.to_i
    JWT.encode(
      { sub: user_id.to_s, level: "verified", iss: issuer, aud: audience, iat: now - 7200, exp: now - 3600 },
      keypair, "RS256",
    )
  end
end
