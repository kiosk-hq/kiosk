# frozen_string_literal: true

module Kiosk
  # Resolved identity of the principal making a request.
  # See design spec §6.2 «JWT shape» — this is the canonical Ruby value
  # object an IdP adapter returns from #verify.
  #
  # Immutable. Compared by value.
  #
  # @!attribute [r] user_id
  #   The principal id (whatever the provider's user-id type is — uuid,
  #   bigint, integer, text). The principal need NOT be a human; it may
  #   be a synthetic placeholder, service account, group, or parent agent
  #   depending on the user-IdP adapter (see spec §6.1).
  # @!attribute [r] role
  #   The active role for this token — one of the configured `Kiosk.roles`.
  # @!attribute [r] actor
  #   `"agent"` | `"human"` | `"service"` — channel kind, recorded for
  #   audit and Action-level gating; NEVER appears in RLS policies.
  # @!attribute [r] agent_id
  #   Present iff `actor == "agent"`. Identifies the specific agent
  #   credential (multi-agent per user — see spec §6.4).
  # @!attribute [r] claims
  #   Hash of additional claims from the upstream IdP. Adapter-specific;
  #   Kiosk treats opaque except for the four canonical fields above.
  Identity = Data.define(:user_id, :role, :actor, :agent_id, :claims) do
    VALID_ACTORS = %w[agent human service].freeze

    def initialize(user_id:, role:, actor:, agent_id: nil, claims: {})
      raise ArgumentError, "user_id required" if user_id.nil?
      raise ArgumentError, "role required"    if role.nil? || role.to_s.empty?

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
        role:     role.to_s,
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
