# frozen_string_literal: true

require "openssl"
require "jwt"

# ProveKey — the broker's RSA issuer key ("the ProveKey"), the key each operator
# TRUSTS once (skooti sets c.kyc_public_key = ProveKey.public_key). The broker
# signs every anonymized claim with it, and the operator's
# Kiosk::Server::KycVerifier accepts it because this broker is its configured
# c.kyc_issuer. Broker compromise = trust root (design §4 residual risk).
#
# The key is configured per environment (K-672/K-673, read in
# config/environments/*.rb into Rails.configuration.x.prove.key_pem):
# development/test load the FIXED dev keypair from config/dev_prove_key.pem, so
# a pinned local copy survives restarts. Production REFUSES to boot unless
# PROVE_KEY_PEM names a fresh private key — the dev key's private half ships in
# this public repo, so signing with it would let anyone forge attestations.
#
# BROKER-ONLY (K-681): a sibling demo's Rails has no `x.prove`, so this file
# works only inside the booted kiosk-demo-prove app and must not be required
# across an app boundary. Standalone drivers mint with
# kiosk-demo-skooti/script/prove_test_issuer.rb, off the same dev_prove_key.pem.
module ProveKey
  module_function

  # The broker's own prove config, or a signpost. Rails being loaded is NOT
  # enough: a sibling demo's Rails answers `configuration.x.prove` with an empty
  # OrderedOptions and every read comes back nil — hence the key_pem probe
  # (K-672/K-673). No fallback key: an unconfigured process must fail, not mint.
  def config
    cfg = ::Rails.configuration.x.prove if defined?(::Rails) && ::Rails.respond_to?(:configuration)
    return cfg if cfg && cfg.key_pem

    raise <<~MSG
      ProveKey reads the broker's per-environment config
      (Rails.configuration.x.prove — K-672/K-673) and therefore only works
      inside the booted kiosk-demo-prove broker.

      It was reached from a process that is not that broker: either no Rails
      at all (a standalone driver), or a DIFFERENT app's Rails, whose config
      has no `x.prove` block. Flow/redteam drivers must NOT load this file —
      they mint with kiosk-demo-skooti/script/prove_test_issuer.rb, which reads
      the same config/dev_prove_key.pem without the Rails dependency (K-681).
    MSG
  end

  # The `iss` the broker stamps into every claim; operators set c.kyc_issuer to
  # the SAME value and their KycVerifier compares the two. Both sides default to
  # the deploy origin kyc.demo.kiosk.tech; configured per environment (K-672).
  def issuer
    config.issuer
  end

  # The signing keypair, from per-environment config (K-673). Production's env
  # file has already crash-checked that PROVE_KEY_PEM parses as a private key.
  def keypair
    @keypair ||= OpenSSL::PKey::RSA.new(config.key_pem)
  end

  # The RSA public key PEM — operators pin this as c.kyc_public_key.
  def public_key
    keypair.public_key.to_pem
  end

  # Mint a signed, anonymized, per-request claim — the JWS the operator's
  # KycVerifier accepts. It binds subject + operator + request:
  #   sub        — the operator's user_id for the requesting agent; KycVerifier
  #                rejects a claim whose sub != the authenticated agent (the
  #                cross-subject / IssuedKycJwsTheft defense).
  #   iss        — issuer (operators configure this as c.kyc_issuer).
  #   level      — "verified" (KycVerifier requires this literal).
  #   attributes — the granted anonymized booleans, e.g. {age_over_18:true} —
  #                only booleans, never a DOB or a licence number.
  #   operator   — the operator_id the claim is addressed to (kept for the
  #                operator's callback correlation and logging).
  #   aud        — OPERATOR-BINDING: the operator's KycVerifier REJECTS a claim
  #                whose `aud` != its configured `kyc_audience`, so a claim
  #                minted for operator A is rejected at operator B AT THE WIRE,
  #                not merely by a demo's own callback. Defaults to `operator`.
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
