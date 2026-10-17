# frozen_string_literal: true

module Kiosk
  # The principal making a request, as an IdP adapter's #verify returns it.
  # `actor` is "agent", "human" or "service"; `agent_id` is present iff the
  # actor is an agent and must be a uuid (the schema types it so, with no knob).
  Identity = Data.define(:user_id, :role, :actor, :agent_id, :claims)

  # Validation and the actor predicates.
  class Identity
    VALID_ACTORS = %w[agent human service].freeze

    def initialize(user_id:, role:, actor:, agent_id: nil, claims: {})
      actor = actor.to_s
      validate!(user_id, actor, agent_id)
      role = role.to_s
      super(user_id:, role: (role unless role.empty?), actor:, agent_id:, claims: claims || {})
    end

    def agent?   = actor == 'agent'
    def human?   = actor == 'human'
    def service? = actor == 'service'

    private

    def validate!(user_id, actor, agent_id)
      raise ArgumentError, 'user_id required' if user_id.nil?

      validate_actor!(actor)
      validate_agent_id!(actor, agent_id)
    end

    def validate_actor!(actor)
      return if VALID_ACTORS.include?(actor)

      raise ArgumentError, "actor must be one of #{VALID_ACTORS.inspect}, got #{actor.inspect}"
    end

    def validate_agent_id!(actor, agent_id)
      if actor == 'agent'
        raise ArgumentError, "agent_id required when actor == 'agent'" if agent_id.to_s.empty?
      elsif agent_id
        raise ArgumentError, "agent_id must be nil when actor != 'agent' (got actor=#{actor.inspect})"
      end
    end
  end
end
