# frozen_string_literal: true

module Kiosk
  # Postgres GUC (Grand Unified Configuration) names that Kiosk uses to carry
  # identity from an HTTP request into the Postgres session.
  #
  # Default namespace is `app` (short, ergonomic in policy text). Providers
  # whose primary backend already uses `app.*` for its own settings can
  # override via `Kiosk.configure { |c| c.guc_namespace = "kiosk" }`.
  module GUC
    DEFAULT_NAMESPACE = "app"

    # Suffix names — the namespace is prepended at runtime via `.for`.
    USER_ID  = "current_user_id"
    ROLE     = "current_role"
    ACTOR    = "current_actor"
    AGENT_ID = "current_agent_id"

    ALL = [USER_ID, ROLE, ACTOR, AGENT_ID].freeze

    # Compose the full GUC name for `SET LOCAL` statements.
    #
    # @example
    #   Kiosk::GUC.for("app", Kiosk::GUC::USER_ID) #=> "app.current_user_id"
    def self.for(namespace, name)
      "#{namespace}.#{name}"
    end
  end
end
