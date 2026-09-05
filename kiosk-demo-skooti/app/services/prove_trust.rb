# frozen_string_literal: true

require "openssl"

# ProveTrust — skooti's TRUST configuration for the shared anonymizing KYC
# broker at kyc.demo.kiosk.tech. skooti hosts no issuer of its own: it points
# c.kyc_issuer / c.kyc_public_key at the broker and trusts the broker's signing
# key (the "ProveKey") once — trust it once, ask it for exactly the claims
# skooti needs.
#
# Only the environment-INDEPENDENT identity values live here (not in Rails
# config), because the flow/redteam drivers load this as a plain module OUTSIDE
# a Rails boot. The environment-DEPENDENT trust material — the broker PUBLIC KEY
# and skooti's intake SECRET — is set in config/environments/*.rb from the env
# (Rails.configuration.x.kiosk.prove_public_key_pem / .prove_intake_secret),
# with NO shipped fallback for either.
module ProveTrust
  module_function

  # The `iss` the broker signs into every claim; skooti sets c.kyc_issuer to it.
  # Both sides read KIOSK_PROVE_ISSUER and default to the SAME value, so plain
  # `rails s` (no env) and the deploy (one env for both apps) line up. Default is
  # the origin the broker is deployed at.
  def issuer
    ENV.fetch("KIOSK_PROVE_ISSUER", "https://kyc.demo.kiosk.tech")
  end

  # Where request_kyc calls the broker's intake. Defaults to the deployed broker
  # origin; the two-server harness overrides it with the local broker's host:port.
  def broker_url
    ENV.fetch("KIOSK_PROVE_BROKER_URL", "https://kyc.demo.kiosk.tech")
  end

  # skooti's identity at the broker's intake, which authenticates it.
  def operator_id
    ENV.fetch("KIOSK_PROVE_OPERATOR_ID", "skooti")
  end
end
