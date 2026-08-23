# frozen_string_literal: true

require "openssl"

# ProveTrust — getgrocery's TRUST configuration for the shared anonymizing KYC
# broker at kyc.demo.kiosk.tech. getgrocery hosts no KYC issuer of its own: it
# points c.kyc_issuer / c.kyc_public_key at the broker and trusts the broker's
# signing key (the "ProveKey") once, then asks it for exactly the claims it
# needs — here just `age_over_18` for the alcohol age gate, NOT a driving
# licence.
#
# Only the environment-INDEPENDENT identity values live here, as a plain module
# rather than in Rails config, because the flow/redteam drivers load it OUTSIDE
# a Rails boot. The trust MATERIAL — the broker public key and getgrocery's
# intake secret — comes from Rails custom config (K-650) with NO shipped
# fallback for either.
module ProveTrust
  module_function

  # The broker issuer identity — must match the broker's own ProveKey.issuer.
  # Both sides read KIOSK_PROVE_ISSUER and default to the SAME value, so plain
  # `rails s` and specs (which set no env) line up without configuration.
  def issuer
    ENV.fetch("KIOSK_PROVE_ISSUER", "https://kyc.demo.kiosk.tech")
  end

  # Where request_kyc calls the broker's intake. Defaults to the deployed broker
  # origin; the two-server harness overrides it with the local broker's port.
  def broker_url
    ENV.fetch("KIOSK_PROVE_BROKER_URL", "https://kyc.demo.kiosk.tech")
  end

  # getgrocery's identity at the broker's intake — a distinct operator from
  # skooti, with its own handle and its own secret.
  def operator_id
    ENV.fetch("KIOSK_PROVE_OPERATOR_ID", "getgrocery")
  end
end
