# frozen_string_literal: true

# Runs the registered Kiosk queries/actions AS the signed-in human, so the web
# UI and the agent wire share ONE world. The human has no agent token — the
# provider's own Devise session IS the authentication — so we build a `human`
# Kiosk::Identity for `current_user` and open a Kiosk::Server::SessionContext,
# which sets the same `app.current_user_id` GUC the wire path sets. Inside it,
# `kiosk.current_user_id()` resolves to the signed-in human and every registered
# handler's membership check works identically to an agent call.
#
# TWO THINGS THE HANDLERS-AS-CONTROLLERS MIGRATION (T-057) CHANGED HERE, both
# because a handler is now a Rails action rather than a stored block:
#
#   1. The identity is published on {Kiosk::Server::CurrentRequest} as well as
#      in the GUCs. WireController already does this for a wire request; this is
#      the second entrance to the same handlers, and without it a handler
#      reading `kiosk_identity` — which is where tudu's principal and acting
#      agent now come from — would see nil for every web call. The GUCs alone
#      were enough while every handler reached the principal through SQL.
#   2. `kiosk_run` returns STRING keys. A handler answers with `render json:`,
#      and the seam that dispatches it hands back the parsed JSON, so
#      `value["list_id"]` is the shape now (it used to be the `{list_id: …}`
#      Ruby hash the block returned). Query rows were always string-keyed —
#      they come from `conn.execute` — so nothing there moved.
#
# And one thing the CALLERS had to change: a handler's refusal is a rendered
# status now, so it arrives as {Kiosk::Server::Errors::WireError} carrying the
# wire CODE, not as the `Errors::Forbidden`/`BadRequest` CLASS the initializer
# handlers raised. The taxonomy was never the contract (T-054) — the code table
# is — so the web actions rescue the base class and branch on `e.code`.
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
    kiosk_as_human { Kiosk::Server::Queries.fetch(name).call(params) }
  end

  # Run a registered action handler as the human, returning its value.
  def kiosk_run(name, args = {})
    kiosk_as_human { Kiosk::Server::Actions.fetch(name).call(args) }
  end

  # The GUC transaction and the identity carrier, together — the same two things
  # WireController establishes around a wire dispatch, so a handler cannot tell
  # which door it was reached through.
  def kiosk_as_human
    identity = human_identity
    result   = nil
    Kiosk::Server::CurrentRequest.with(identity: identity) do
      Kiosk::Server::SessionContext.open(
        connection: ActiveRecord::Base.connection, identity: identity,
      ) { result = yield }
    end
    result
  end
end
