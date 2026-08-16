# frozen_string_literal: true

# Runs tudu's domain work AS the signed-in human, so the web UI and the agent
# wire share ONE world. The human has no agent token — the provider's own Devise
# session IS the authentication — so we build a `human` Kiosk::Identity for
# `current_user` and open a Kiosk::Server::SessionContext, which sets the same
# `app.current_user_id` GUC the wire path sets. Inside it,
# `kiosk.current_user_id()` resolves to the signed-in human and every membership
# check works identically to an agent call.
#
# WRITES NO LONGER GO THROUGH THE WIRE DISPATCHER (K-654). They used to:
# `kiosk_run(name, args)` looked the verb up in the process-wide Action registry
# and dispatched a synthetic Rack sub-request at the handler controller, purely
# because that controller was where the write logic lived. The logic is in
# app/operations/ now, so a web action calls the Operation directly inside
# {#kiosk_as_human} — same GUC, same transaction, same principal, one less
# round trip through a serialize/parse boundary that existed only to reach code
# on the other side of it. `kiosk_run` is gone with its last caller.
#
# QUERIES still go through the registry ({#kiosk_query}). They are reads: their
# logic is a scope on a model plus a `pluck`, there is nothing to extract, and
# the handler controller IS the natural home for a projection. A refusal from
# one therefore still arrives as {Kiosk::Server::Errors::WireError} carrying the
# wire CODE — the taxonomy was never the contract (T-054), the code table is —
# so the read actions rescue the base class and branch on `e.code`. The WRITE
# actions branch on {OperationResult#code}, which is the same string.
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

  # The GUC transaction and the identity carrier, together — the same two things
  # WireController establishes around a wire dispatch, so the domain cannot tell
  # which door it was reached through. Yields the identity, because an Operation
  # takes its principal as an argument rather than reading request state.
  def kiosk_as_human
    identity = human_identity
    result   = nil
    Kiosk::Server::CurrentRequest.with(identity: identity) do
      Kiosk::Server::SessionContext.open(
        connection: ActiveRecord::Base.connection, identity: identity,
      ) { result = yield identity }
    end
    result
  end

  # A refusal this surface has no presentation for. It leaves the controller
  # exactly as it did when writes ran through the wire dispatcher — same class,
  # same message — so a `bad_request` on a page that only knows how to show a
  # `forbidden` still surfaces loudly instead of being swallowed by a friendly
  # redirect.
  def kiosk_refusal!(result)
    raise Kiosk::Server::Errors::WireError.new(
      result.message, code: result.code, hint: result.hint
    )
  end
end
