# frozen_string_literal: true

module Kiosk
  # Postgres GUC names that carry identity from the request into the session.
  module GUC
    DEFAULT_NAMESPACE = "app"

    USER_ID  = "current_user_id"
    ROLE     = "current_role"
    ACTOR    = "current_actor"
    AGENT_ID = "current_agent_id"

    def self.for(namespace, name)
      "#{namespace}.#{name}"
    end
  end
end
