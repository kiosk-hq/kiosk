# frozen_string_literal: true

require "openssl"
require "jwt"

# ProveKey — the broker's RSA issuer key ("the ProveKey"). This is the key each
# operator TRUSTS once (skooti sets c.kyc_public_key = ProveKey.public_key). The
# broker signs every anonymized claim with it; the operator's
# Kiosk::Server::KycVerifier accepts the claim because this broker is its configured
# c.kyc_issuer and the signature verifies against this key.
#
# The key itself is configured per environment (K-672/K-673 — read in
# config/environments/*.rb into Rails.configuration.x.prove.key_pem):
# development/test load the FIXED dev keypair from config/dev_prove_key.pem
# (stable across restarts, so a hand-wired local operator's pinned copy stays
# valid; the two-server harnesses fetch the public half from the running
# broker's GET /prove_key.pem and need no fixed value), while production
# REFUSES to boot unless PROVE_KEY_PEM is set to a fresh private key (K-673):
# the dev key's private half ships in this public repo, so silently signing
# with it would let anyone forge attestations operators trust. This module is
# the direct analogue of skooti's retired StubKyc, extracted into the
# standalone broker. Broker compromise = trust root (design §4 residual risk).
#
#   ProveKey.public_key        → PEM string (operators pin this)
#   ProveKey.mint(...)         → compact RS256 JWS (posted to the operator callback)
#   ProveKey.issuer            → the `iss` value operators configure as c.kyc_issuer
module ProveKey
  module_function

  # The `iss` the broker stamps into every claim. Operators set c.kyc_issuer
  # to the SAME value (their KycVerifier compares the minted `iss` against it);
  # both sides default to the registered deploy origin kyc.demo.kiosk.tech and
  # the two-server harnesses pin a matching value on both sides. Configured per
  # environment (KIOSK_PROVE_ISSUER, read in config/environments/*.rb — K-672).
  def issuer
    Rails.configuration.x.prove.issuer
  end

  # The signing keypair, from per-environment config (K-673): dev/test load
  # the baked config/dev_prove_key.pem; production's env file has already
  # crash-checked that PROVE_KEY_PEM is set, parses, and is a private key.
  def keypair
    @keypair ||= OpenSSL::PKey::RSA.new(Rails.configuration.x.prove.key_pem)
  end

  # The RSA public key PEM — operators pin this as c.kyc_public_key.
  def public_key
    keypair.public_key.to_pem
  end

  # Mint a signed, anonymized, per-request claim. This is the heart of the
  # callback: the JWS the operator's KycVerifier accepts.
  #
  # The claim binds to (subject + operator + request):
  #   sub        — the operator's user_id for the requesting agent (KycVerifier
  #                rejects a claim whose sub != the authenticated agent — the
  #                cross-subject/IssuedKycJwsTheft defense, unchanged).
  #   iss        — issuer (operators configure this as c.kyc_issuer).
  #   level      — "verified" (KycVerifier requires this literal).
  #   attributes — the granted anonymized booleans, e.g. {age_over_18:true,
  #                licence_a:true}. Only booleans — never DOB/licence number.
  #   operator   — the operator_id the claim is addressed to (the human-readable
  #                broker handle; retained for the operator's callback correlation
  #                and logging).
  #   aud        — the OPERATOR-BINDING audience the claim is minted FOR. The
  #                operator's engine Kiosk::Server::KycVerifier REJECTS any claim
  #                whose `aud` != its configured `kyc_audience` — so a claim minted
  #                for operator A is rejected at operator B AT THE WIRE (not merely
  #                by a demo's own callback). Defaults to `operator` when the
  #                operator did not declare a distinct audience.
  #   request_id — the broker request this claim answers (callback correlation).
  #   nonce      — echoes the request nonce (callback anti-replay).
  #   iat/exp    — short-lived (default 1h).
  #
  # @return [String] compact RS256 JWS
  def mint(subject:, operator:, attributes:, request_id:, nonce:, audience: nil, ttl: 3600)
    now = Time.now.to_i
    JWT.encode(
      {
        sub:        subject.to_s,
        level:      "verified",
        iss:        issuer,
        operator:   operator.to_s,
        aud:        (audience.nil? || audience.to_s.empty? ? operator.to_s : audience.to_s),
        request_id: request_id.to_s,
        nonce:      nonce.to_s,
        attributes: attributes,
        iat:        now,
        exp:        now + ttl.to_i,
      },
      keypair, "RS256",
    )
  end
end
