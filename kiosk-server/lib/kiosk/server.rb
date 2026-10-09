# frozen_string_literal: true

# kiosk-server: the Rails engine, its wire, auth and discovery controllers, and
# the install generator. See https://kiosk.tech.

require "kiosk"

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
require "kiosk/server/issuer_middleware"
require "kiosk/server/well_known"
require "kiosk/server/open_api"
require "kiosk/server/schema_definitions"
require "kiosk/server/errors"
require "kiosk/server/failure_log"
require "kiosk/server/result"
require "kiosk/server/session_context"
require "kiosk/owned"
require "kiosk/server/schema_slots"
require "kiosk/server/actions"
require "kiosk/server/queries"
require "kiosk/server/events"
require "kiosk/server/event_store"
require "kiosk/server/event_stores"
require "kiosk/server/events_cable"
require "kiosk/server/events_connection"
require "kiosk/server/kiosk_events_channel"
require "kiosk/server/action_event"
require "kiosk/server/audit_sink"
require "kiosk/server/schema_document"
require "kiosk/server/current_request"
require "kiosk/server/handler_dispatch"
require "kiosk/server/handler_mixin"
require "kiosk/server/handler_registrations"
require "kiosk/handler"
require "kiosk/server/executor"
require "kiosk/server/column_spending_cap"
require "kiosk/server/payment_claim"
require "kiosk/server/agent_identity_providers/default_agent_idp"
require "kiosk/server/identity_resolution"
require "kiosk/server/pow_spent_stores"
require "kiosk/server/pow_gate"
require "kiosk/server/argument_decoder"
require "kiosk/server/request_validation"
require "kiosk/server/registration_pow"
require "kiosk/server/agent_registration"
require "kiosk/server/auth_challenge_store"
require "kiosk/server/auth_challenge_stores"
require "kiosk/server/revocation_store"
require "kiosk/server/auth_challenge"
require "kiosk/server/pop_verifier"
require "kiosk/server/agent_login"
require "kiosk/server/kyc_verifier"
require "kiosk/server/mandate_verifier"

require "kiosk/server/engine"

require "kiosk/server/wire_controller"
require "kiosk/server/verb_controller"
require "kiosk/server/payment_setup_controller"
require "kiosk/server/open_api_controller"
require "kiosk/server/discovery_controller"
require "kiosk/server/jwks_controller"
require "kiosk/server/binding_module_gate"
require "kiosk/server/oauth_device_authorization_controller"
require "kiosk/server/oauth_token_controller"
require "kiosk/server/account_holder_gate"
require "kiosk/server/device_verify_controller"
require "kiosk/server/assistants_controller"
require "kiosk/server/auth_controller"
require "kiosk/server/kyc_attestation_controller"
require "kiosk/server/kyc_callback_controller"

module Kiosk
  module Server
    # Pieces shipped in this gem:
    #
    #   Wire plane:
    #   - {Kiosk::Server::Executor}         — wire dispatch (query/run/pay/schema)
    #   - {Kiosk::Server::WireController}   — Rails controller wrapping Executor
    #   - {Kiosk::Server::VerbController}   — the per-verb wire: GET <endpoint>/<query>, POST <endpoint>/<action>
    #   - {Kiosk::Server::PaymentSetup}     — `payment_setup` and its topic
    #   - {Kiosk::Server::PaymentSetupController} — GET <endpoint>/payment_setup/return
    #   - {Kiosk::Server::Kyc}              — `request_kyc`, its topic and the grants
    #   - {Kiosk::Server::KycCallbackController} — POST <endpoint>/kyc/callback
    #   - {Kiosk::Server::ArgumentDecoder}  — query string → typed arguments
    #   - {Kiosk::Server::Actions}          — action registry
    #   - {Kiosk::Server::Queries}          — query registry
    #   - {Kiosk::Handler}                  — mixin declaring verbs as Rails controller actions
    #   - {Kiosk::Server::Result}           — success payload value type
    #   - {Kiosk::Server::Errors}           — exception hierarchy + RFC 9457 problem documents
    #   - {Kiosk::Server::SessionContext}   — transaction + transaction-local GUCs
    #   - {Kiosk::Server::ActionEvent}      — one action invocation, as the audit sink receives it
    #   - {Kiosk::Server::AuditSink}        — emits one event per action invocation to `c.audit_sink`
    #
    #   Auth plane (kiosk-pop proof-of-possession, the default IdP):
    #   - {Kiosk::Server::AgentRegistration} — register an agent key
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
    #   - {Kiosk::Server::WellKnown}        — discovery documents
    #   - {Kiosk::Server::DiscoveryController} — serves the discovery documents
    #   - {Kiosk::Server::OpenApi}          — OpenAPI 3.1 description of this origin's verbs
    #   - {Kiosk::Server::OpenApiController} — serves <mount>/openapi.json
    #   - {Kiosk::Server::SigningKey}       — RSA keypair value object
    #   - {Kiosk::Server::Jwks}             — JWKS document builder (RFC 7517)
    #   - {Kiosk::Server::JwtIssuer}        — RS256 sign / verify
    #   - {Kiosk::Server::JwksController}   — serves /.well-known/jwks.json
    #
    #   Event plane:
    #   - {Kiosk::Server::Events}           — topic registry and `emit`
    #   - {Kiosk::Server::EventStore}       — in-process tail, for tests
    #   - {Kiosk::Server::EventStores}      — ActiveRecord-backed tail, the default
    #   - {Kiosk::Server::EventsCable}      — the engine's own Action Cable server
    #   - {Kiosk::Server::EventsConnection} — the socket's identity
    #   - {KioskEvents}                     — the channel; top-level because its name is on the wire
    #
    #   Infra:
    #   - {Kiosk::Server::Headers}          — composes the response headers
    #   - {Kiosk::Server::HeadersMiddleware}— Rack middleware that injects them
    #   - {Kiosk::Server::SchemaDefinitions}— SQL for the canonical migrations
    #   - {Kiosk::Server::Engine}           — Rails engine
    #
    #   Account-binding ceremony (RFC 8628 claim/link):
    #   - {Kiosk::Server::DeviceAuthorization}        — ceremony state machine (kind: claim/link)
    #   - {Kiosk::Server::DeviceAuthorizationStores}  — storage adapters
    #   - {Kiosk::Server::DeviceCodeGrant}            — claim flow: .start + .exchange
    #   - {Kiosk::Server::DeviceVerification}         — verify-page helpers
    #   - {Kiosk::Server::AccountBinding}             — fresh-register / rebind / unlink + hooks
    #   - {Kiosk::Server::LinkCode}                   — link flow: .mint + .redeem
    #   - {Kiosk::Server::BindingModuleGate}          — the `501 module_not_served` refusal
    #   - {Kiosk::Server::AccountHolderGate}          — the signed-in-human check for the HTML pages
    #   - {Kiosk::Server::OauthDeviceAuthorizationController} — POST /oauth/device_authorization
    #   - {Kiosk::Server::OauthTokenController}        — POST /oauth/token
    #   - {Kiosk::Server::DeviceVerifyController}      — GET/POST /oauth/device/verify
    #   - {Kiosk::Server::AssistantsController}        — «Link an assistant» page

    # Path to the pinned reference event-stream listener shipped in this gem.
    def self.listener_path
      File.expand_path("../../listen.py", __dir__)
    end
  end
end
