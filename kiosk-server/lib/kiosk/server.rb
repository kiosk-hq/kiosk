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
require "kiosk/server/rental_token_issuer"
require "kiosk/server/mandate_verifier"

# Optional Rails engine — only defines itself if Rails::Engine is loaded.
require "kiosk/server/engine"

# Conditionally loaded — only defines WireController + JwksController +
# OAuth controllers when ActionController::API is available (i.e., a
# Rails host). Safe to require in plain Ruby contexts.
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
    #   - {Kiosk::Server::WellKnown}        — builds /.well-known/kiosk.json
    #   - {Kiosk::Server::SigningKey}       — RSA keypair value object
    #   - {Kiosk::Server::Jwks}             — JWKS document builder (RFC 7517)
    #   - {Kiosk::Server::JwtIssuer}        — RS256 sign / verify
    #   - {Kiosk::Server::DeviceAuthorization}        — RFC 8628 Device-Grant value object
    #   - {Kiosk::Server::DeviceAuthorizationStores}  — storage adapter (InMemory ships; ActiveRecord follows)
    #   - {Kiosk::Server::DeviceCodeGrant}            — pure-Ruby service: .start + .exchange
    #   - {Kiosk::Server::DeviceVerification}         — pure-Ruby helpers: .find_pending + .approve + .deny
    #   - {Kiosk::Server::OauthDeviceAuthorizationController} — POST /oauth/device_authorization
    #   - {Kiosk::Server::OauthTokenController}        — POST /oauth/token (device_code grant)
    #   - {Kiosk::Server::Headers}          — composes the three response headers
    #   - {Kiosk::Server::HeadersMiddleware}— Rack middleware that injects them
    #   - {Kiosk::Server::SchemaDefinitions}— SQL for migrations 001-004
    #   - {Kiosk::Server::Errors}           — exception hierarchy + envelope serialisation
    #   - {Kiosk::Server::Result}           — success envelope value type
    #   - {Kiosk::Server::SessionContext}   — transaction + four SET LOCAL GUCs
    #   - {Kiosk::Server::Actions}          — minimal Action registry (full DSL later)
    #   - {Kiosk::Server::RentalTokenIssuer} — Ed25519 offline rental-token sign/verify (Arch 2)
    #   - {Kiosk::Server::Executor}         — wire dispatch (query/run/pay/schema working; events stubbed)
    #   - {Kiosk::Server::WireController}   — Rails controller wrapping Executor (only when Rails loaded)
    #   - {Kiosk::Server::JwksController}   — Rails controller serving /.well-known/jwks.json (only when Rails loaded)
    #   - {Kiosk::Server::Engine}           — Rails engine (only when Rails loaded)
  end
end
