# frozen_string_literal: true

require "openssl"

# ProveTrust — skooti's TRUST configuration for the prove.my broker (the shared
# anonymizing KYC issuer). skooti no longer hosts its own KYC issuer: it points
# c.kyc_issuer / c.kyc_public_key at prove.my and trusts prove.my's signing key
# (the "ProveKey") once. This is the whole point of a shared broker — trust it
# once, ask it for exactly the claims skooti needs.
#
# The trust anchors are read from the environment so the two-server demo:kyc
# harness (which boots the broker on its own port and knows its URL + public
# key) can wire them in, with a pinned fallback that matches the broker's fixed
# dev ProveKey so plain `rails s` / specs still boot coherently.
#
#   ProveTrust.issuer     — the `iss` value prove.my signs into every claim;
#                           skooti sets c.kyc_issuer to this.
#   ProveTrust.public_key — the ProveKey RSA public PEM; skooti sets
#                           c.kyc_public_key to this so KycVerifier accepts the
#                           broker's signatures.
#   ProveTrust.broker_url — where request_kyc calls the broker's intake.
#   ProveTrust.operator_id / .intake_secret — skooti's identity + shared secret
#                           at the broker's intake (the broker authenticates
#                           skooti and refuses arbitrary callers).
module ProveTrust
  module_function

  # The broker issuer identity — must match the broker's ProveKey::ISSUER. The
  # harness may override via KIOSK_PROVE_ISSUER; default is the production brand.
  def issuer
    ENV.fetch("KIOSK_PROVE_ISSUER", "https://prove.my")
  end

  # The ProveKey public PEM skooti trusts. Preference order:
  #   1. KIOSK_PROVE_PUBLIC_KEY_PEM  (the harness pins the running broker's key)
  #   2. the pinned dev ProveKey PEM below (matches the broker's fixed dev key)
  def public_key
    env = ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"]
    return env if env && !env.empty?

    PINNED_DEV_PROVE_PUBLIC_PEM
  end

  # Where request_kyc calls the broker's intake endpoint.
  def broker_url
    ENV.fetch("KIOSK_PROVE_BROKER_URL", "https://prove.my")
  end

  # skooti's operator id + shared secret at the broker's intake.
  def operator_id
    ENV.fetch("KIOSK_PROVE_OPERATOR_ID", "skooti")
  end

  def intake_secret
    ENV.fetch("KIOSK_PROVE_SKOOTI_SECRET", "prove-skooti-demo-shared-secret")
  end

  # Pinned public half of the broker's fixed dev ProveKey (kiosk-demo-prove
  # lib/prove_key.rb DEV_PRIVATE_PEM). Kept here so skooti boots with a coherent
  # trust anchor even without the harness env; the harness overrides it with the
  # live broker's key anyway.
  PINNED_DEV_PROVE_PUBLIC_PEM = <<~PEM
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyOq6o7Dt2ykoGBW6Uzzi
    WfECwkuStu2KStpfm/pVnVdJVY9Ghew+Qt4kRNLfK86UdeEG7+4umEPQ0juXdu/h
    NtAVbvY6PgHhdupe9+m/Z4EEeoxEU/tM9IMIf4G2ji2Zk5UG+kCMu0+QrZQneCw2
    TLCrJn1y4T8nSNgbnKYfMnM4WeWhL483rPC2HIv1ItiOq7buj/iDGhRdLuZxQVA8
    uqkWGsGoqJ8lDLvY/w5fmcQo2w0TcDG0IBzG2Y1VYUfke86Vu1WllElyGQqss+/Y
    H6bhui994FvcATQYtonaBqzLg/iLBl5n1WkM3hZTLnC3mJlbKpnPdQ1vubRI8w8d
    +wIDAQAB
    -----END PUBLIC KEY-----
  PEM
end
