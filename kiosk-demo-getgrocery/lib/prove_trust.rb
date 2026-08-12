# frozen_string_literal: true

require "openssl"

# ProveTrust — getgrocery's TRUST configuration for the KYC broker demo at
# kyc.demo.kiosk.tech (the shared anonymizing KYC issuer). getgrocery does NOT host its own KYC issuer: it
# points c.kyc_issuer / c.kyc_public_key at the broker and trusts the broker's
# signing key (the "ProveKey") once. This is the whole point of a shared broker
# — trust it once, ask it for exactly the claims getgrocery needs (here, just
# `age_over_18` for the alcohol age-gate — NOT a driving licence).
#
# This module carries only the environment-INDEPENDENT identity values, kept
# here (not in Rails config) because the flow/redteam drivers load it as a
# plain module OUTSIDE a Rails boot. The environment-DEPENDENT trust material
# moved to Rails custom config (K-650): the broker PUBLIC KEY and getgrocery's
# intake SECRET are set in config/environments/*.rb from the env
# (Rails.configuration.x.kiosk.prove_public_key_pem / .prove_intake_secret) —
# with NO shipped fallback for either. The old pinned dev ProveKey PEM and the
# dev intake-secret default are gone: the two-server demo:agecheck harness
# (ProveBrokerBoot) pins the running broker's key and the shared secret
# explicitly on both sides, so nothing needs to line up "out of the box".
#
#   ProveTrust.issuer      — the `iss` value the broker signs into every claim;
#                            getgrocery sets c.kyc_issuer to this.
#   ProveTrust.broker_url  — where request_kyc calls the broker's intake.
#   ProveTrust.operator_id — getgrocery's identity at the broker's intake.
#                            getgrocery is a SECOND broker operator alongside
#                            skooti; the two-server test harness registers it
#                            (deploy allow-listing is a follow-up).
module ProveTrust
  module_function

  # The broker issuer identity — must match the broker's ProveKey.issuer. Both
  # read KIOSK_PROVE_ISSUER and default to the SAME value, so plain `rails s` /
  # specs (which set no env) and the deploy (which sets it once for all apps)
  # both line up. The two-server harness pins it explicitly on both sides.
  def issuer
    ENV.fetch("KIOSK_PROVE_ISSUER", "https://kyc.demo.kiosk.tech")
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
end
