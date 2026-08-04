# frozen_string_literal: true

require "openssl"
require "jwt"

# ProveTestIssuer — a TEST-ONLY signer that mints attestations with the broker's
# ProveKey PRIVATE key, for skooti's flow/redteam/isolation scaffolding that
# needs a VALID (or expired) attestation for a given user_id WITHOUT driving the
# full broker HTTP round-trip (e.g. "KYC a fresh agent so only the gate under
# test can block"). It is the direct analogue of the retired StubKyc.attest —
# but now signing with the SHARED broker key skooti trusts (c.kyc_public_key =
# ProveTrust.public_key = the ProveKey public half).
#
# This reaches into the sibling kiosk-demo-prove app's ProveKey to get the
# private key — acceptable because it is TEST scaffolding in the same monorepo,
# not runtime app code (runtime issuance lives ONLY in the broker). It signs a
# minimal claim carrying just what KycVerifier checks (sub/iss/level/exp) plus
# the anonymized attributes; the operator/nonce/request_id fields the async
# callback path uses are irrelevant here (this bypasses the callback).
#
#   ProveTestIssuer.attest(user_id:, attributes:) → compact RS256 JWS
#   ProveTestIssuer.attest_expired(user_id:)       → same, but exp 1h in the past
module ProveTestIssuer
  # Load the broker's ProveKey (sibling app). Path is relative to this file so it
  # resolves whether required from a flow, the redteam, or a rake task.
  PROVE_KEY_PATH = File.expand_path("../../kiosk-demo-prove/lib/prove_key.rb", __dir__)

  module_function

  def keypair
    require PROVE_KEY_PATH unless defined?(::ProveKey)
    @keypair ||= ProveKey.keypair
  end

  def issuer
    require PROVE_KEY_PATH unless defined?(::ProveKey)
    ProveKey::ISSUER
  end

  # The operator-binding audience the minted claims carry as `aud`. Sourced from
  # ProveTrust.operator_id — the SAME value skooti sets as c.kyc_audience — so the
  # engine's operator-binding check passes on the test-issuer path exactly as on
  # the real broker path. Read from ProveTrust (not Kiosk.configuration) because
  # the flow/redteam drivers run as STANDALONE scripts (no Kiosk config booted),
  # while ProveTrust is a plain module both the drivers and the server load.
  def audience
    require File.expand_path("prove_trust", __dir__) unless defined?(::ProveTrust)
    ProveTrust.operator_id
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
