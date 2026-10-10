# frozen_string_literal: true

# The actions. The work is in app/operations, which the human pages call too.
class Kiosk::TodoListsController < ApplicationController
  include Kiosk::Handler

  topic :todo do
    reach :consented
    description "A todo on a list you can reach was added or completed — by any member, " \
                "your own calls included, or by a human clicking Done in the browser."
    payload_schema type: "object", additionalProperties: false,
                   properties: { todo_id: { type: "string", format: "uuid" },
                                 title:   { type: "string" },
                                 done:    { type: "boolean" },
                                 action:  { enum: %w[added completed] } },
                   required: %w[todo_id done action]
    subject_reachable ->(list_id, identity) { Membership.readable_by?(list_id, identity.user_id) }
  end

  topic :list_membership do
    reach :consented
    description "Somebody joined or left a list you can reach — a third principal redeemed " \
                "an invite, or an owner removed a member."
    payload_schema type: "object", additionalProperties: false,
                   properties: { account_id: { type: "string", format: "uuid" },
                                 role:       { type: "string" },
                                 action:     { enum: %w[joined removed] } },
                   required: %w[account_id action]
    subject_reachable ->(list_id, identity) { Membership.readable_by?(list_id, identity.user_id) }
  end

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
    render json: CreateListOperation.call(
      principal_id: kiosk_identity.user_id, title: params[:title],
    )
  end

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
                 due_at:  { type: "string", format: "date-time",
                            description: "Deadline, RFC 3339, and the OFFSET IS REQUIRED: a " \
                                         "deadline is an INSTANT, so a value without one is refused " \
                                         "rather than completed on anybody's clock. Resolve «tomorrow " \
                                         "at two» YOURSELF, on the clock of the human who said it — " \
                                         "whoever else shares this list reads it on theirs, and " \
                                         "`list_todos` renders it in the zone each caller declares in " \
                                         "`Kiosk-Timezone`. Omit it for a todo with no deadline." },
               },
               required: ["list_id", "title"]
  output_schema type: "object",
                description: "The added todo.",
                additionalProperties: false,
                properties: {
                  todo_id: { type: "string", description: "uuid. Pass to complete_todo as `todo_id`." },
                },
                required: ["todo_id"]
  example_params({ list_id: "d4e5f6a7-8b9c-4d0e-9f1a-2b3c4d5e6f70", title: "Book campsite",
                   due_at: -> { ReaderClock.default_zone.now.tomorrow.change(hour: 14).iso8601 } })
  example_row({ todo_id: "7f2a1b3c-4d5e-4a6b-8c9d-0e1f2a3b4c5d" })
  def add_todo
    render json: AddTodoOperation.call(
      agent_id: kiosk_identity.agent_id, list_id: params[:list_id], title: params[:title],
      due_at: params[:due_at],
    )
  end

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
    render json: CompleteTodoOperation.call(todo_id: params[:todo_id])
  end

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
    render json: InviteOperation.call(
      principal_id: kiosk_identity.user_id, list_id: params[:list_id],
    )
  end

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
    render json: AcceptInviteOperation.call(
      principal_id: kiosk_identity.user_id, code: params[:code],
    )
  end

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
    render json: RemoveMemberOperation.call(
      list_id: params[:list_id], account_id: params[:account_id],
    )
  end
end
