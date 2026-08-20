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
#
# BROKER-ONLY (K-681). Because the key and the issuer now come from the
# broker's own per-environment config, this file works ONLY inside the booted
# kiosk-demo-prove app, and must not be required across the app boundary. It
# was — skooti's ProveTestIssuer loaded it in-process back when it was a
# self-contained constant carrier — and K-672 turned that into a silent trap:
# nil key_pem inside skooti's Rails (whose config has no `x.prove`), and
# `uninitialized constant ProveKey::Rails` in the bare-Ruby drivers. The
# drivers now resolve their own key (kiosk-demo-skooti/lib/prove_test_issuer.rb
# reads the SAME config/dev_prove_key.pem, no Rails); #config below makes a
# repeat of that mistake say so, instead of surfacing as a nil TypeError.
module ProveKey
  module_function

  # The broker's own prove config, or a signpost. Rails being loaded is NOT
  # enough: a sibling demo's Rails answers `configuration.x.prove` with an
  # empty OrderedOptions, so every read comes back nil — hence the key_pem
  # probe, which only the broker's environment files satisfy (K-672/K-673).
  # Deliberately no fallback key here: the point of K-673 is that this module
  # signs with the key its environment supplied and nothing else, so an
  # unconfigured process must fail rather than mint.
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
      they mint with kiosk-demo-skooti/lib/prove_test_issuer.rb, which reads
      the same config/dev_prove_key.pem without the Rails dependency (K-681).
    MSG
  end

  # The `iss` the broker stamps into every claim. Operators set c.kyc_issuer
  # to the SAME value (their KycVerifier compares the minted `iss` against it);
  # both sides default to the registered deploy origin kyc.demo.kiosk.tech and
  # the two-server harnesses pin a matching value on both sides. Configured per
  # environment (KIOSK_PROVE_ISSUER, read in config/environments/*.rb — K-672).
  def issuer
    config.issuer
  end

  # The signing keypair, from per-environment config (K-673): dev/test load
  # the baked config/dev_prove_key.pem; production's env file has already
  # crash-checked that PROVE_KEY_PEM is set, parses, and is a private key.
  def keypair
    @keypair ||= OpenSSL::PKey::RSA.new(config.key_pem)
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
