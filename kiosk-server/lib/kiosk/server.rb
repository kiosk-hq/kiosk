# frozen_string_literal: true

# kiosk-server — Rails engine (when in a Rails host) + pure-Ruby pieces
# (well-known doc builder, headers, schema-migration SQL) that don't need
# a host. See https://kiosk.tech and design spec §3, §6.7.

require "kiosk"
require "kiosk/rls"

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
require "kiosk/server/executor"
require "kiosk/server/agent_identity_providers/default_agent_idp"
require "kiosk/server/agent_registration"
require "kiosk/server/proof_of_work"
require "kiosk/server/kyc_verifier"
require "kiosk/server/unlock_authority"
require "kiosk/server/mandate_verifier"

# Optional Rails engine — only defines itself if Rails::Engine is loaded.
require "kiosk/server/engine"

# Conditionally loaded — only defines ExecController + JwksController +
# OAuth controllers when ActionController::API is available (i.e., a
# Rails host). Safe to require in plain Ruby contexts.
require "kiosk/server/exec_controller"
require "kiosk/server/jwks_controller"
require "kiosk/server/oauth_device_authorization_controller"
require "kiosk/server/oauth_token_controller"
require "kiosk/server/agents_registration_controller"
require "kiosk/server/kyc_attestation_controller"

module Kiosk
  module Server
    # Pieces shipped in this gem:
    #
    #   - {Kiosk::Server::WellKnown}        — builds /.well-known/kiosk.json
    #   - {Kiosk::Server::SigningKey}       — RSA keypair value object (§6.2)
    #   - {Kiosk::Server::Jwks}             — JWKS document builder (RFC 7517)
    #   - {Kiosk::Server::JwtIssuer}        — RS256 sign / verify (§6.2, §6.7)
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
    #   - {Kiosk::Server::Executor}         — six-verb dispatch (sql/run working; pay/schema/help/events stubbed)
    #   - {Kiosk::Server::ExecController}   — Rails controller wrapping Executor (only when Rails loaded)
    #   - {Kiosk::Server::JwksController}   — Rails controller serving /.well-known/jwks.json (only when Rails loaded)
    #   - {Kiosk::Server::Engine}           — Rails engine (only when Rails loaded)
  end
end
