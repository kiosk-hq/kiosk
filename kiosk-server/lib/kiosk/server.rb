# frozen_string_literal: true

# kiosk-server — the Rails engine, the nine wire/auth/discovery controllers,
# the install generator, and the pure-Ruby pieces they build on (well-known
# doc builder, headers, schema-migration SQL). See https://kiosk.tech.
#
# This is a Rails gem: railties, actionpack, activerecord and activesupport
# are declared runtime dependencies (see the gemspec) and are loaded here
# unconditionally. Individual files require the framework piece they use.

require "kiosk"

# ActiveRecord::Base.lease_connection is how the auth plane and the durable
# device-authorization store reach the database; nothing in this gem
# provides an alternative for those paths. Every statement they run carries
# BIND PARAMETERS (K-654, K-782) — this gem calls `connection.quote` nowhere.
require "active_record"

require "kiosk/server/version"
require "kiosk/server/signing_key"
require "kiosk/server/jwks"
require "kiosk/server/jwt_issuer"
require "kiosk/server/device_authorization"
require "kiosk/server/device_authorization_stores"
require "kiosk/server/device_code_grant"
require "kiosk/server/device_verification"
require "kiosk/server/account_binding"
require "kiosk/server/link_code"
require "kiosk/server/configuration_extension"
require "kiosk/server/headers"
require "kiosk/server/headers_middleware"
require "kiosk/server/well_known"
require "kiosk/server/open_api"
require "kiosk/server/schema_definitions"
require "kiosk/server/errors"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/server/actions"
require "kiosk/server/queries"
require "kiosk/server/schema_document"
require "kiosk/server/current_request"
require "kiosk/server/handler_dispatch"
require "kiosk/server/handler_mixin"
require "kiosk/server/handler_registrations"
require "kiosk/action"
require "kiosk/query"
require "kiosk/operation_result"
require "kiosk/server/executor"
require "kiosk/server/column_spending_cap"
require "kiosk/server/agent_identity_providers/default_agent_idp"
require "kiosk/server/identity_resolution"
require "kiosk/server/pow_spent_store"
require "kiosk/server/pow_spent_stores"
require "kiosk/server/pow_gate"
require "kiosk/server/argument_decoder"
require "kiosk/server/request_validation"
require "kiosk/server/registration_pow"
require "kiosk/server/agent_registration"
require "kiosk/server/auth_challenge_store"
require "kiosk/server/revocation_store"
require "kiosk/server/auth_challenge"
require "kiosk/server/pop_verifier"
require "kiosk/server/agent_login"
require "kiosk/server/kyc_verifier"
require "kiosk/server/mandate_verifier"

require "kiosk/server/engine"

# Controllers. This block loads the wire surface (WireController), the
# discovery surface (DiscoveryController —
# agents.txt/json, agent-configuration, kiosk.json, api-catalog, auth.md),
# JWKS (JwksController), the kiosk-pop auth surface (AuthController — NOT
# OAuth — plus the link/claim/unlink binding endpoints), the KYC attestation
# surface (KycAttestationController), and the account-binding ceremony's
# OAuth-wire + HTML controllers.
require "kiosk/server/wire_controller"
require "kiosk/server/verb_controller"
require "kiosk/server/open_api_controller"
require "kiosk/server/discovery_controller"
require "kiosk/server/jwks_controller"
require "kiosk/server/oauth_device_authorization_controller"
require "kiosk/server/oauth_token_controller"
require "kiosk/server/device_verify_controller"
require "kiosk/server/assistants_controller"
require "kiosk/server/auth_controller"
require "kiosk/server/kyc_attestation_controller"

module Kiosk
  module Server
    # Pieces shipped in this gem:
    #
    #   Wire plane:
    #   - {Kiosk::Server::Executor}         — wire dispatch (query/run/pay/schema)
    #   - {Kiosk::Server::WireController}   — Rails controller wrapping Executor
    #   - {Kiosk::Server::VerbController}   — the 0.4 per-verb wire:
    #                                         GET <endpoint>/<query-name>,
    #                                         POST <endpoint>/<action-name>
    #   - {Kiosk::Server::ArgumentDecoder}  — a query string → typed arguments,
    #                                         per the T-070/T-087 encoding rule
    #   - {Kiosk::Server::Actions}          — Action registry (name → handler + descriptor)
    #   - {Kiosk::Server::Queries}          — read-side query registry
    #   - {Kiosk::Action} / {Kiosk::Query}  — the mixins an operator includes into
    #                                         a controller of their own to declare
    #                                         verbs as ordinary Rails actions
    #   - {Kiosk::OperationResult}          — answer-or-refusal value object a write
    #                                         Operation returns; subclass it and
    #                                         declare your own STATUSES map
    #   - {Kiosk::Server::Result}           — success envelope value type
    #   - {Kiosk::Server::Errors}           — exception hierarchy + envelope serialisation
    #   - {Kiosk::Server::SessionContext}   — transaction + four transaction-local GUCs
    #
    #   Auth plane (kiosk-pop proof-of-possession — the default IdP):
    #   - {Kiosk::Server::AgentRegistration} — register an agent key (POW-gated)
    #   - {Kiosk::Server::AgentLogin}        — challenge/response login → access token
    #   - {Kiosk::Server::PopVerifier}       — verifies the proof-of-possession signature
    #   - {Kiosk::Server::AuthController}    — Rails controller for the kiosk-pop surface
    #   - {Kiosk::Server::IdentityResolution} — resolves agent_idp then user_idp → Identity
    #   - {Kiosk::Server::PowGate}           — gates verbs behind a proof-of-work toll
    #   - {Kiosk::Server::RegistrationPow}   — proof-of-work check for registration
    #
    #   Payment / KYC plane:
    #   - {Kiosk::Server::MandateVerifier}  — verifies agent-signed AP2 mandate JWS
    #   - {Kiosk::Server::KycVerifier}      — verifies a KYC attestation JWS
    #   - {Kiosk::Server::KycAttestationController} — Rails controller for the KYC surface
    #
    #   Signing / discovery:
    #   - {Kiosk::Server::WellKnown}        — discovery generator: kiosk.json (build), agents.txt, agents.json, agent-configuration, api-catalog (RFC 9727), auth.md
    #   - {Kiosk::Server::DiscoveryController} — serves those six discovery docs
    #   - {Kiosk::Server::SigningKey}       — RSA keypair value object
    #   - {Kiosk::Server::Jwks}             — JWKS document builder (RFC 7517)
    #   - {Kiosk::Server::JwtIssuer}        — RS256 sign / verify (kiosk-pop access tokens)
    #   - {Kiosk::Server::JwksController}   — Rails controller serving /.well-known/jwks.json
    #
    #   Infra:
    #   - {Kiosk::Server::Headers}          — composes the three response headers
    #   - {Kiosk::Server::HeadersMiddleware}— Rack middleware that injects them
    #   - {Kiosk::Server::SchemaDefinitions}— SQL for migrations 001-010
    #   - {Kiosk::Server::Engine}           — Rails engine
    #
    #   Account-binding ceremony (the RFC 8628 machinery revived
    #   as the key-bound claim/link surface; kiosk-pop stays the only token
    #   story):
    #   - {Kiosk::Server::DeviceAuthorization}        — ceremony state machine (kind: claim/link)
    #   - {Kiosk::Server::DeviceAuthorizationStores}  — storage adapters (durable ActiveRecord default + InMemory)
    #   - {Kiosk::Server::DeviceCodeGrant}            — claim flow service: .start + .exchange (BIND-POP)
    #   - {Kiosk::Server::DeviceVerification}         — verify-page helpers: .find_pending + .approve + .deny
    #   - {Kiosk::Server::AccountBinding}             — fresh-register / rebind / unlink + the assistant_claimed / assistant_unlinked hooks
    #   - {Kiosk::Server::LinkCode}                   — link flow service: .mint + .redeem
    #   - {Kiosk::Server::OauthDeviceAuthorizationController} — POST /oauth/device_authorization
    #   - {Kiosk::Server::OauthTokenController}        — POST /oauth/token (device_code grant)
    #   - {Kiosk::Server::DeviceVerifyController}      — GET/POST /oauth/device/verify (HTML, overridable views)
    #   - {Kiosk::Server::AssistantsController}        — «Link an assistant» page (HTML, overridable views)
  end
end
