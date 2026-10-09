# frozen_string_literal: true

module Kiosk
  # The principal making a request, as an IdP adapter's #verify returns it.
  # `actor` is "agent", "human" or "service"; `agent_id` is present iff the
  # actor is an agent and must be a uuid (the schema types it so, with no knob).
  Identity = Data.define(:user_id, :role, :actor, :agent_id, :claims) do
    VALID_ACTORS = %w[agent human service].freeze

    def initialize(user_id:, role:, actor:, agent_id: nil, claims: {})
      raise ArgumentError, "user_id required" if user_id.nil?

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
