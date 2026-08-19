# frozen_string_literal: true

# tudu's WRITE surface: the six verbs an assistant reaches with
# `POST /kiosk/run` — the most of any demo. Same shape as
# Kiosk::HouseholdController — this app's own ApplicationController plus
# `include Kiosk::Action` — because a controller declares queries OR actions,
# never both.
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
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire carries it verbatim. No
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
  include Kiosk::Action
  include KioskRefusals

  # create_list(title) — INSERT a list owned by the AUTHENTICATED principal and,
  # in the SAME transaction, an `owner` membership for the caller. Any forged
  # account_id/owner_id arg is IGNORED: the owner is read from the identity the
  # wire resolved, never from params.
  description "Create a new todo list owned by the authenticated principal. The " \
              "caller becomes its owner (an owner membership is created). Any forged " \
              "account_id/owner_id arg is ignored (owner is the authenticated " \
              "principal). Returns { list_id }."
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
  description "Add a todo to a list the caller is a member of. The acting agent " \
              "is recorded on the todo (attribution). Forbidden (403) if the caller " \
              "is not a member. Returns { todo_id }."
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
  description "Mark a todo done. Allowed only if the caller is a member of the " \
              "todo's list; otherwise forbidden (403). Returns { todo_id, done }."
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
  description "Owner-only: mint a single-use, 10-minute collaboration code for a " \
              "list you own. The plaintext code is returned ONCE (only its hash is " \
              "stored) and is meant to be handed to another person, whose assistant " \
              "redeems it with accept_invite. Forbidden (403) if you are not the " \
              "list owner. Returns { code, expires_in }."
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
  description "Redeem a collaboration code someone shared with you: join their " \
              "list as a member. The code is single-use and expires; a used, " \
              "expired, or unknown code is forbidden (403). Returns { list_id, joined }."
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
