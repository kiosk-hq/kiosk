# frozen_string_literal: true

# kiosk-server — Rails engine (when in a Rails host) + pure-Ruby pieces
# (well-known doc builder, headers, schema-migration SQL) that don't need
# a host. See https://kiosk.tech.

require "kiosk"

require "kiosk/server/version"
require "kiosk/server/signing_key"
require "kiosk/server/jwks"
require "kiosk/server/jwt_issuer"
require "kiosk/server/device_authorization"
require "kiosk/server/device_authorization_stores"
require "kiosk/server/device_code_grant"
require "kiosk/server/device_verification"
require "kiosk/server/configuration_extension"
require "kiosk/server/headers"
require "kiosk/server/headers_middleware"
require "kiosk/server/well_known"
require "kiosk/server/schema_definitions"
require "kiosk/server/errors"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/server/actions"
require "kiosk/server/queries"
require "kiosk/server/executor"
require "kiosk/server/agent_identity_providers/default_agent_idp"
require "kiosk/server/identity_resolution"
require "kiosk/server/pow_spent_store"
require "kiosk/server/pow_gate"
require "kiosk/server/registration_pow"
require "kiosk/server/agent_registration"
require "kiosk/server/auth_challenge_store"
require "kiosk/server/revocation_store"
require "kiosk/server/auth_challenge"
require "kiosk/server/pop_verifier"
require "kiosk/server/agent_login"
require "kiosk/server/kyc_verifier"
require "kiosk/server/mandate_verifier"

# Optional Rails engine — only defines itself if Rails::Engine is loaded.
require "kiosk/server/engine"

# Controllers — each file defines its controller only when
# ActionController::API is available (i.e., a Rails host); safe to require in
# plain Ruby contexts. This block loads the wire surface (WireController),
# JWKS (JwksController), the kiosk-pop auth surface (AuthController — NOT
# OAuth), the KYC attestation surface (KycAttestationController), and the
# dormant OAuth 2.1 device-grant controllers (per ADR-0008).
require "kiosk/server/wire_controller"
require "kiosk/server/jwks_controller"
require "kiosk/server/oauth_device_authorization_controller"
require "kiosk/server/oauth_token_controller"
require "kiosk/server/auth_controller"
require "kiosk/server/kyc_attestation_controller"

module Kiosk
  module Server
    # Pieces shipped in this gem:
    #
    #   Wire plane:
    #   - {Kiosk::Server::Executor}         — wire dispatch (query/run/pay/schema)
    #   - {Kiosk::Server::WireController}   — Rails controller wrapping Executor (only when Rails loaded)
    #   - {Kiosk::Server::Actions}          — minimal Action registry (full DSL later)
    #   - {Kiosk::Server::Queries}          — read-side query registry
    #   - {Kiosk::Server::Result}           — success envelope value type
    #   - {Kiosk::Server::Errors}           — exception hierarchy + envelope serialisation
    #   - {Kiosk::Server::SessionContext}   — transaction + four SET LOCAL GUCs
    #
    #   Auth plane (kiosk-pop proof-of-possession — the default IdP):
    #   - {Kiosk::Server::AgentRegistration} — register an agent key (POW-gated)
    #   - {Kiosk::Server::AgentLogin}        — challenge/response login → access token
    #   - {Kiosk::Server::PopVerifier}       — verifies the proof-of-possession signature
    #   - {Kiosk::Server::AuthController}    — Rails controller for the kiosk-pop surface (only when Rails loaded)
    #   - {Kiosk::Server::IdentityResolution} — resolves agent_idp then user_idp → Identity
    #   - {Kiosk::Server::PowGate}           — gates verbs behind a proof-of-work toll
    #   - {Kiosk::Server::RegistrationPow}   — proof-of-work check for registration
    #
    #   Payment / KYC plane:
    #   - {Kiosk::Server::MandateVerifier}  — verifies agent-signed AP2 mandate JWS
    #   - {Kiosk::Server::KycVerifier}      — verifies a KYC attestation JWS
    #   - {Kiosk::Server::KycAttestationController} — Rails controller for the KYC surface (only when Rails loaded)
    #
    #   Signing / discovery:
    #   - {Kiosk::Server::WellKnown}        — builds /.well-known/kiosk.json
    #   - {Kiosk::Server::SigningKey}       — RSA keypair value object
    #   - {Kiosk::Server::Jwks}             — JWKS document builder (RFC 7517)
    #   - {Kiosk::Server::JwtIssuer}        — RS256 sign / verify (kiosk-pop access tokens)
    #   - {Kiosk::Server::JwksController}   — Rails controller serving /.well-known/jwks.json (only when Rails loaded)
    #
    #   Infra:
    #   - {Kiosk::Server::Headers}          — composes the three response headers
    #   - {Kiosk::Server::HeadersMiddleware}— Rack middleware that injects them
    #   - {Kiosk::Server::SchemaDefinitions}— SQL for migrations 001-007
    #   - {Kiosk::Server::Engine}           — Rails engine (only when Rails loaded)
    #
    #   Dormant OAuth 2.1 device-grant surface (code retained, unwired — ADR-0008):
    #   - {Kiosk::Server::DeviceAuthorization}        — RFC 8628 Device-Grant value object
    #   - {Kiosk::Server::DeviceAuthorizationStores}  — storage adapter (only an InMemory store ships)
    #   - {Kiosk::Server::DeviceCodeGrant}            — pure-Ruby service: .start + .exchange
    #   - {Kiosk::Server::DeviceVerification}         — pure-Ruby helpers: .find_pending + .approve + .deny
    #   - {Kiosk::Server::OauthDeviceAuthorizationController} — POST /oauth/device_authorization
    #   - {Kiosk::Server::OauthTokenController}        — POST /oauth/token (device_code grant)
  end
end
