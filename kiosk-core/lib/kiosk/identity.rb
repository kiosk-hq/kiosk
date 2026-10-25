# frozen_string_literal: true

module Kiosk
  # The principal of a request, as the #verify of an identity adapter returns
  # it. `actor` says who makes the request:
  #   "agent"   — an AI assistant with an access token. kiosk-server makes it.
  #   "human"   — a person signed in on the site of the operator. The `user_idp`
  #               adapter makes it, for example kiosk-user-idp-devise.
  #   "service" — a program of the operator, for an adapter that the operator
  #               writes. No Kiosk gem makes it.
  # The audit sink receives the actor of each action, and SQL reads it with
  # `kiosk.current_actor()`.
  # `agent_id` is the UUID of the assistant: present for an agent, nil otherwise.
  Identity = Data.define(:user_id, :role, :actor, :agent_id, :claims)

  # Validates user_id, actor and agent_id on construction.
  class Identity
    VALID_ACTORS = %w[agent human service].freeze

    def initialize(user_id:, role:, actor:, agent_id: nil, claims: {})
      actor = actor.to_s
      validate!(user_id, actor, agent_id)
      role = role.to_s
      super(user_id:, role: (role unless role.empty?), actor:, agent_id:, claims: claims || {})
    end

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
