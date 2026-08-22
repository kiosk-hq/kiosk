# frozen_string_literal: true

# tudu's WRITE surface: the six verbs an assistant reaches with
# `POST /kiosk/<action-name>` — one endpoint per verb (protocol 0.4), and the
# most of any demo. The arguments ARE the JSON body; there is no `name` field
# and no multiplexed `/kiosk/run`. Same shape as
# Kiosk::HouseholdController — this app's own ApplicationController plus
# `include Kiosk::Handler` — with `kind :action` above each declaration, which is
# what puts it on `POST`.
#
# EVERY ACTION BELOW IS FOUR LINES: read the arguments off the request, hand
# them to an Operation, render what it answers. That is deliberate and it is
# what K-654 changed here beyond swapping SQL for ActiveRecord. tudu is the one
# demo whose HUMAN web UI drives the same writes (app/controllers/lists_ and
# todos_controller), and while the write logic lived in these methods the only
# way for the web UI to reach it was to dispatch a synthetic Rack sub-request at
# this controller. The logic moved to app/operations/, both surfaces call it
# directly, and what is left here is genuinely a controller's job: params in,
# `render json:` out.
#
# Errors are Rails' idiom end to end: the wire's error-code vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire carries it verbatim into
# the RFC 9457 problem document's top-level `code` member. No
# Kiosk error classes appear below — an Operation answers with an
# {OperationResult}, and {KioskRefusals#render_operation} is the one place
# that becomes a status.
#
# tudu advertises NO `pay` verb and configures no payment provider, so nothing
# here means a 402: the wire's three payment/PoW codes share that status and
# `Errors::STATUS_CODES` deliberately refuses to guess between them, and the only
# 402 an assistant meets on this origin comes from the registration PoW gate
# upstream of dispatch, never from a handler.
#
# NOT ROUTABLE — see Kiosk::HouseholdController.
class Kiosk::TodoListsController < ApplicationController
  include Kiosk::Handler
  include KioskRefusals

  # create_list(title) — INSERT a list owned by the AUTHENTICATED principal and,
  # in the SAME transaction, an `owner` membership for the caller. The owner is
  # read from the identity the wire resolved, never from params — and since 0.4
  # a forged account_id/owner_id cannot even be sent: `input_schema` is validated
  # on every call and the closed object below declares only `title`, so the wire
  # answers 400 bad_request naming the parameter. The description says so,
  # because "this argument is ignored" and "this argument is refused" are
  # different instructions to an assistant.
  kind :action
  description "Create a new todo list for the authenticated principal, who becomes its owner in the " \
              "same transaction. Ownership is NOT an input: it is taken from the identity the operator " \
              "resolved, and an argument that tries to name a different owner is REFUSED with a 400 " \
              "rather than quietly ignored — «this is ignored» and «this is refused» are different " \
              "instructions to an assistant, and this origin gives the second."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 title: { type: "string", minLength: 1, description: "The list title." },
               },
               required: ["title"]
  output_schema type: "object",
                description: "The created list.",
                additionalProperties: false,
                properties: {
                  list_id: { type: "string", description: "uuid. Pass to list_todos / add_todo / invite as `list_id`." },
                },
                required: ["list_id"]
  example_params({ title: "Hike" })
  example_row({ list_id: "d4e5f6a7-8b9c-4d0e-9f1a-2b3c4d5e6f70" })
  def create_list
    render_operation CreateListOperation.call(
      principal_id: kiosk_identity.user_id, title: params[:title],
    )
  end

  # add_todo(list_id, title) — membership-gated; records the acting agent as
  # created_by_agent_id (attribution: "who added the tent? — Bob's assistant").
  # nil for the human web surface, which has no agent.
  # `reach :consented` — §7.2 is about what a verb may AFFECT as much as what it
  # may read, and this one writes onto a list another account owns. Same
  # artefact as the read side: the membership permits it, and a non-member is
  # refused 403 by the same gate.
  kind :action
  reach :consented
  description "Add a todo to a list the caller is a member of. The acting assistant is recorded on " \
              "the todo, so a household can see later who put it there — «who added the tent?» is an " \
              "answerable question on this origin. Forbidden (403) if the caller is not a member."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id: { type: "string", format: "uuid",
                            description: "The list to add to — a `list_id` from my_lists, verbatim." },
                 title:   { type: "string", minLength: 1, description: "The todo text." },
               },
               required: ["list_id", "title"]
  output_schema type: "object",
                description: "The added todo.",
                additionalProperties: false,
                properties: {
                  todo_id: { type: "string", description: "uuid. Pass to complete_todo as `todo_id`." },
                },
                required: ["todo_id"]
  def add_todo
    render_operation AddTodoOperation.call(
      agent_id: kiosk_identity.agent_id, list_id: params[:list_id], title: params[:title],
    )
  end

  # complete_todo(todo_id) — membership-gated via the todo's list. One UPDATE
  # scoped to the caller's memberships; zero rows → 403 (probing can't
  # enumerate ids).
  # `reach :consented` — updates a row on somebody else's list when the caller
  # is a member of it.
  kind :action
  reach :consented
  description "Mark a todo done. Allowed only if the caller is a member of the list the todo is on; " \
              "otherwise forbidden (403) — and the refusal reads the same whether the todo belongs to " \
              "somebody else or does not exist at all, so probing cannot enumerate."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 todo_id: { type: "string", format: "uuid",
                            description: "The todo to complete — a `todo_id` from list_todos, verbatim." },
               },
               required: ["todo_id"]
  output_schema type: "object",
                description: "The completed todo.",
                additionalProperties: false,
                properties: {
                  todo_id: { type: "string", description: "The todo that was completed, echoed." },
                  done:    { const: true, description: "true — a refusal is an error, never `done: false`." },
                },
                required: %w[todo_id done]
  def complete_todo
    render_operation CompleteTodoOperation.call(todo_id: params[:todo_id])
  end

  # invite(list_id) — OWNER-ONLY. Mint a single-use, TTL'd (10 min) collaboration
  # code; store ONLY its SHA-256 digest; return the plaintext { code, expires_in }
  # ONCE. The code travels human-to-human; the recipient's agent redeems it via
  # accept_invite.
  kind :action
  description "Owner-only: mint a single-use, ten-minute collaboration secret for a list you own. " \
              "The plaintext is handed back ONCE and never again — this origin stores only its hash — " \
              "and it is meant to travel person-to-person, out of band, to somebody whose assistant " \
              "redeems it with `accept_invite` and joins. Forbidden (403) if you are not the list's " \
              "owner."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id: { type: "string", format: "uuid",
                            description: "The list to share — a `list_id` from my_lists " \
                                         "that you own, verbatim." },
               },
               required: ["list_id"]
  output_schema type: "object",
                description: "The minted collaboration code — returned ONCE.",
                additionalProperties: false,
                properties: {
                  code:       { type: "string", description: "The PLAINTEXT code, returned once and never again (only its hash is stored). Hand it to the other person; their assistant redeems it with accept_invite." },
                  expires_in: { type: "integer", description: "Seconds from now until the code stops being redeemable." },
                },
                required: %w[code expires_in]
  def invite
    render_operation InviteOperation.call(
      principal_id: kiosk_identity.user_id, list_id: params[:list_id],
    )
  end

  # accept_invite(code) — look up by digest; reject foreign/expired/redeemed (403);
  # INSERT a `member` membership for the principal; mark redeemed. A used code
  # fails on the second try (single-use). Returns { list_id, joined: true }.
  # `reach :consented` — THE VERB THAT MINTS THE ARTEFACT EVERY OTHER
  # `consented` VERB HERE RELIES ON. It reads an invite another account created
  # and inserts a membership on that account's list, so it is cross-principal in
  # both directions; and it is the moment the consent becomes a row this
  # operator can point at, which is what makes the claim `consented` rather than
  # `published`.
  kind :action
  reach :consented
  description "Redeem a collaboration secret somebody shared with you and join their list as a " \
              "member. It is single-use and short-lived: one that has already been redeemed, one whose " \
              "ten minutes have run out, and one this origin never minted are all forbidden (403), and " \
              "all three read the same, so a guesser learns nothing from the refusal."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 code: { type: "string", minLength: 1,
                         description: "The plaintext invite code you were given." },
               },
               required: ["code"]
  output_schema type: "object",
                description: "The list just joined.",
                additionalProperties: false,
                properties: {
                  list_id: { type: "string", description: "uuid — the list you are now a member of. Pass it to list_todos / add_todo as `list_id`." },
                  joined:  { const: true, description: "true — a used, expired or unknown code is a 403, never `joined: false`." },
                },
                required: %w[list_id joined]
  def accept_invite
    render_operation AcceptInviteOperation.call(
      principal_id: kiosk_identity.user_id, code: params[:code],
    )
  end

  # remove_member(list_id, account_id) — OWNER-ONLY. DELETE the target's
  # membership; access is cut instantly. The owner cannot remove the LAST owner
  # (no orphaning the list). Returns { removed: true }.
  # `reach :consented` — deletes a `memberships` row whose `account_id` is
  # ANOTHER principal's, which the default reach forbids outright. `invite` next
  # door needs no declaration by contrast: it is owner-only and mints a row on a
  # list the caller already owns, so it never leaves the principal.
  kind :action
  reach :consented
  description "Owner-only: remove a member from a list you own — their access is " \
              "cut instantly. You cannot remove the list's last owner. Forbidden " \
              "(403) if you are not the owner. Returns { removed }."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id:    { type: "string", format: "uuid",
                               description: "The list to remove a member from — a `list_id` " \
                                            "from my_lists that you own, verbatim." },
                 account_id: { type: "string", format: "uuid",
                               description: "The member account to remove — an `account_id` " \
                                            "from list_members, verbatim." },
               },
               required: ["list_id", "account_id"]
  output_schema type: "object",
                description: "The removal.",
                additionalProperties: false,
                properties: {
                  removed: { const: true, description: "true — a refusal (not the owner, or the last owner) is a 403, never `removed: false`." },
                },
                required: ["removed"]
  def remove_member
    render_operation RemoveMemberOperation.call(
      list_id: params[:list_id], account_id: params[:account_id],
    )
  end
end
