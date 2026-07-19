# frozen_string_literal: true

# Runs the registered Kiosk queries/actions AS the signed-in human, so the web
# UI and the agent wire share ONE world. The human has no agent token — the
# provider's own Devise session IS the authentication — so we build a `human`
# Kiosk::Identity for `current_user` and open a Kiosk::Server::SessionContext,
# which sets the same `app.current_user_id` GUC the wire path sets. Inside it,
# `kiosk.current_user_id()` resolves to the signed-in human and every registered
# handler's membership check works identically to an agent call.
module KioskSessionable
  extend ActiveSupport::Concern

  private

  # Human identity: no agent_id (actor: human) — attribution columns stay null
  # for web-added rows, exactly like an assistant-less action.
  def human_identity
    Kiosk::Identity.new(
      user_id: current_user.id,
      role:    Kiosk.configuration.roles.first.to_s,
      actor:   "human",
    )
  end

  # Run a registered query handler as the human, returning its rows.
  def kiosk_query(name, params = {})
    result = nil
    Kiosk::Server::SessionContext.open(
      connection: ActiveRecord::Base.connection, identity: human_identity,
    ) { result = Kiosk::Server::Queries.fetch(name).call(params) }
    result
  end

  # Run a registered action handler as the human, returning its value.
  def kiosk_run(name, args = {})
    result = nil
    Kiosk::Server::SessionContext.open(
      connection: ActiveRecord::Base.connection, identity: human_identity,
    ) { result = Kiosk::Server::Actions.fetch(name).call(args) }
    result
  end
end
