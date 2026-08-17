# frozen_string_literal: true

# Runs tudu's domain work AS the signed-in human, so the web UI and the agent
# wire share ONE world. The human has no agent token — the provider's own Devise
# session IS the authentication — so we build a `human` Kiosk::Identity for
# `current_user` and open a Kiosk::Server::SessionContext, which sets the same
# `app.current_user_id` GUC the wire path sets. Inside it,
# `kiosk.current_user_id()` resolves to the signed-in human and every membership
# check works identically to an agent call.
#
# THE HUMAN WEB UI NO LONGER TOUCHES THE WIRE DISPATCHER AT ALL — writes since
# K-654, reads since T-082 — and that is the whole point of this file's current
# size. What is left is session/identity plumbing: build the human's identity,
# open the GUC transaction, and turn a refusal this surface cannot present into an
# exception. Nothing here looks a verb up in a registry, and nothing here
# dispatches a synthetic Rack sub-request.
#
# HOW IT USED TO WORK, recorded because the cost is the argument for the seam:
# `kiosk_run(name, args)` and `kiosk_query(name, params)` looked the verb up in
# the process-wide Action/Query registry and ran the handler — the write half by
# dispatching a synthetic sub-request at the handler controller, purely because
# that controller was where the write logic lived. It produced three real breaks
# that existed ONLY because a human request travelled through the wire:
# `kiosk_identity` was nil there (no `Kiosk::Server::CurrentRequest`), results came
# back STRING-keyed because the handler answered `render json:` and the caller
# re-parsed it, and a refusal arrived as `Errors::WireError` carrying a wire code
# rather than as the `Errors::Forbidden` class an existing `rescue` matched on.
#
# WHAT REPLACED EACH HALF. A write is an Operation in app/operations/, called
# directly inside {#kiosk_as_human} — same GUC, same transaction, same principal.
# A read is a MODEL PROJECTION ({List.reachable_rows}, {Todo.rows_on},
# {Membership.rows_on}), called the same way, with the SAME precondition the
# handler uses ({ListAccess}) in front of it. The shared thing is the operation or
# the projection, never the dispatcher — which is exactly what Phil's 2026-08-17
# WRITE-OPERATIONS-SEAM decision asked for, and what leaves the string keys as a
# deliberate published shape rather than an artefact of a JSON round trip.
#
# `Kiosk::Server::CurrentRequest` is gone with the dispatcher: it existed to make
# an identity visible to a handler controller reached through
# `Kiosk::Server::HandlerDispatch`, and nothing on this door is reached that way
# any more. The Operations and projections take their principal from the GUC (or
# from the identity this file yields), which is the authority in both doors.
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

  # The GUC transaction — the same one WireController establishes around a wire
  # dispatch, so the domain cannot tell which door it was reached through. Yields
  # the identity, because an Operation takes its principal as an argument rather
  # than reading request state.
  def kiosk_as_human
    identity = human_identity
    result   = nil
    Kiosk::Server::SessionContext.open(
      connection: ActiveRecord::Base.connection, identity: identity,
    ) { result = yield identity }
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
