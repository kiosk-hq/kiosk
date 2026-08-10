# frozen_string_literal: true

require "openssl"

# ProveTrust — getgrocery's TRUST configuration for the prove.my broker (the
# shared anonymizing KYC issuer). getgrocery does NOT host its own KYC issuer: it
# points c.kyc_issuer / c.kyc_public_key at prove.my and trusts prove.my's
# signing key (the "ProveKey") once. This is the whole point of a shared broker
# — trust it once, ask it for exactly the claims getgrocery needs (here, just
# `age_over_18` for the alcohol age-gate — NOT a driving licence).
#
# The trust anchors are read from the environment so the two-server demo:agecheck
# harness (which boots the broker on its own port and knows its URL + public key)
# can wire them in, with a pinned fallback that matches the broker's fixed dev
# ProveKey so plain `rails s` / specs still boot coherently.
#
#   ProveTrust.issuer     — the `iss` value prove.my signs into every claim;
#                           getgrocery sets c.kyc_issuer to this.
#   ProveTrust.public_key — the ProveKey RSA public PEM; getgrocery sets
#                           c.kyc_public_key to this so KycVerifier accepts the
#                           broker's signatures.
#   ProveTrust.broker_url — where request_kyc calls the broker's intake.
#   ProveTrust.operator_id / .intake_secret — getgrocery's identity + shared
#                           secret at the broker's intake (the broker
#                           authenticates getgrocery and refuses arbitrary
#                           callers). getgrocery is a SECOND broker operator
#                           alongside skooti; the two-server test harness
#                           registers it (deploy allow-listing is a follow-up).
module ProveTrust
  module_function

  # The broker issuer identity — must match the broker's ProveKey.issuer. Both
  # read KIOSK_PROVE_ISSUER and default to the SAME value, so plain `rails s` /
  # specs (which set no env) and the deploy (which sets it once for all apps)
  # both line up. The two-server harness pins it explicitly on both sides.
  def issuer
    ENV.fetch("KIOSK_PROVE_ISSUER", "https://kyc.demo.kiosk.tech")
  end

  # The ProveKey public PEM getgrocery trusts. Preference order:
  #   1. KIOSK_PROVE_PUBLIC_KEY_PEM  (the harness pins the running broker's key)
  #   2. the pinned dev ProveKey PEM below (matches the broker's fixed dev key)
  def public_key
    env = ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"]
    return env if env && !env.empty?

    PINNED_DEV_PROVE_PUBLIC_PEM
  end

  # Where request_kyc calls the broker's intake endpoint. Defaults to the
  # deployed broker origin; the two-server harness overrides it with the local
  # broker's host:port.
  def broker_url
    ENV.fetch("KIOSK_PROVE_BROKER_URL", "https://kyc.demo.kiosk.tech")
  end

  # getgrocery's operator id + shared secret at the broker's intake. getgrocery
  # is a distinct operator from skooti — its own handle and its own secret.
  def operator_id
    ENV.fetch("KIOSK_PROVE_OPERATOR_ID", "getgrocery")
  end

  # The shared bearer secret getgrocery presents to the prove.my broker's intake
  # (Authorization: Bearer …). REQUIRED from the env in production (K-547): a
  # shipped default is world-readable in this public repo, so anyone could
  # impersonate getgrocery's intake. Dev/test keep a fixed default so `rails s`
  # + the two-server demo:kyc harness (which sets the SAME value on both sides)
  # boot out of the box; the broker's KIOSK_PROVE_GETGROCERY_SECRET must match.
  def intake_secret
    ENV.fetch("KIOSK_PROVE_GETGROCERY_SECRET") do
      unless Rails.env.local?
        raise "KIOSK_PROVE_GETGROCERY_SECRET is required outside development/test — it is the " \
              "shared bearer secret getgrocery authenticates to the prove.my broker with; a shipped " \
              "default in a public repo would let anyone impersonate getgrocery's intake (K-547). " \
              "Set the SAME value configured on the broker (its KIOSK_PROVE_GETGROCERY_SECRET)."
      end
      "prove-getgrocery-demo-shared-secret"
    end
  end

  # Pinned public half of the broker's fixed dev ProveKey (kiosk-demo-prove
  # lib/prove_key.rb DEV_PRIVATE_PEM). Kept here so getgrocery boots with a
  # coherent trust anchor even without the harness env; the harness overrides it
  # with the live broker's key anyway.
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
