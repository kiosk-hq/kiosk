# frozen_string_literal: true

module Kiosk
  # Resolved identity of the principal making a request — the canonical
  # Ruby value object an IdP adapter returns from #verify.
  #
  # Immutable. Compared by value.
  #
  # @!attribute [r] user_id
  #   The principal id (whatever the provider's user-id type is — uuid,
  #   bigint, integer, text). The principal need NOT be a human; it may
  #   be a synthetic placeholder, service account, group, or parent agent
  #   depending on the user-IdP adapter.
  # @!attribute [r] role
  #   The active role for this token — one of the configured `Kiosk.roles`,
  #   or +nil+ for a role-less principal (roles are hook-or-absent;
  #   single-role providers need no role at all).
  # @!attribute [r] actor
  #   `"agent"` | `"human"` | `"service"` — channel kind, recorded for
  #   audit and Action-level gating; NEVER appears in RLS policies.
  # @!attribute [r] agent_id
  #   Present iff `actor == "agent"`. Identifies the specific agent
  #   credential (multi-agent per user).
  #
  #   **MUST be a UUID string on a Postgres-backed origin.** This class
  #   validates only that it is PRESENT — the shape constraint comes from the
  #   schema, not from here, and it is a hard one: `agents.id`, the
  #   `agent_id` on `agent_tokens`, `agent_mappings`, `reservations`, the
  #   three AP2 mandate tables, `kyc_attributes`, and the
  #   `kiosk.current_agent_id()` SQL helper are all typed `uuid`. Unlike
  #   {#user_id}, whose type follows `Kiosk.user_id_type`, `agent_id` has NO
  #   configuration knob. An agent-IdP adapter that returns an Okta-shaped or
  #   otherwise opaque agent id therefore builds a valid Identity that fails
  #   later and further down: `pay` cannot settle, the account-binding
  #   ceremony cannot complete, and any RLS policy calling
  #   `kiosk.current_agent_id()` raises on the cast. Map a foreign issuer's
  #   agent identifier onto a local uuid in the adapter (K-830).
  # @!attribute [r] claims
  #   Hash of additional claims from the upstream IdP. Adapter-specific;
  #   Kiosk treats opaque except for the four canonical fields above.
  Identity = Data.define(:user_id, :role, :actor, :agent_id, :claims) do
    VALID_ACTORS = %w[agent human service].freeze

    def initialize(user_id:, role:, actor:, agent_id: nil, claims: {})
      raise ArgumentError, "user_id required" if user_id.nil?

      # Role is optional: absent and empty both mean "no role".
      role = nil if role && role.to_s.empty?

      actor = actor.to_s
      unless VALID_ACTORS.include?(actor)
        raise ArgumentError,
              "actor must be one of #{VALID_ACTORS.inspect}, got #{actor.inspect}"
      end

      if actor == "agent" && (agent_id.nil? || agent_id.to_s.empty?)
        raise ArgumentError, "agent_id required when actor == 'agent'"
      end

      if actor != "agent" && agent_id
        raise ArgumentError,
              "agent_id must be nil when actor != 'agent' (got actor=#{actor.inspect})"
      end

      super(
        user_id:  user_id,
        role:     role&.to_s,
        actor:    actor,
        agent_id: agent_id,
        claims:   claims || {},
      )
    end

    def agent?   = actor == "agent"
    def human?   = actor == "human"
    def service? = actor == "service"
  end
end
