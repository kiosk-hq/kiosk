# frozen_string_literal: true

# The queries. A list is reachable by its members, not only by its owner.
class Kiosk::HouseholdController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "Return who this call is authenticated as: the account the operator resolved for the " \
              "request, the assistant acting on that account's behalf when one is, and the display " \
              "name that account carries in front of the people it shares lists with. A useful first " \
              "call for an assistant orienting itself, and the proof that attribution is wired — " \
              "everything this origin writes is attributed to exactly this pair."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "Exactly one row: the authenticated principal.",
                minItems: 1, maxItems: 1,
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    account_id:   { type: "string", description: "uuid — the principal. Pass it to remove_member as `account_id`." },
                    agent_id:     { type: %w[string null], description: "The acting assistant, or null when a human session is calling." },
                    display_name: { type: "string", description: "The name this account shows to the people it shares lists with — the one it chose, or a stable opaque `member-<hex>` when it has chosen none. Never a login address." },
                  },
                  required: %w[account_id agent_id display_name],
                }
  def whoami
    account_id = kiosk_identity.user_id
    render json: [{ "account_id"   => account_id,
                    "agent_id"     => kiosk_identity.agent_id,
                    "display_name" => User.public_name(User.where(id: account_id).pick(:display_name), account_id) }]
  end

  kind :query
  reach :consented
  description "List the todo lists the authenticated principal can reach. Access here is " \
              "MEMBERSHIP-based rather than owner-scoped, so a list somebody invited the caller into " \
              "is listed alongside the caller's own, and each row says which of the two the caller is " \
              "on it — a distinction that matters, because sharing a list and removing people from it " \
              "are owner-only. Takes no arguments and returns every reachable list. " \
              "Once the human picks one, `list_todos` reads what is on it and " \
              "`add_todo` puts something new there."
  input_schema type: "object",
               additionalProperties: false,
               properties: {},
               required: []
  output_schema type: "array",
                description: "The lists the caller is a member of, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    list_id: { type: "string", description: "uuid. Pass to list_todos / list_members / add_todo / invite / remove_member as `list_id`." },
                    title:   { type: "string", description: "The list title." },
                    role:    { enum: Membership.roles.keys, description: "The CALLER's role on this list — `invite` and `remove_member` are owner-only." },
                  },
                  required: %w[list_id title role],
                }
  example_params({})
  example_row({
    list_id: "d4e5f6a7-8b9c-4d0e-9f1a-2b3c4d5e6f70", title: "Flat 3B", role: "owner",
  })
  def my_lists
    render json: List.reachable_rows
  end

  kind :query
  reach :consented
  description "Return the todos on a list the caller is a member of, each with " \
              "its completion state, the agent that added it, and its deadline if it " \
              "has one. A deadline is stored as one absolute moment and RENDERED IN " \
              "YOUR OWN ZONE — declare it in the `Kiosk-Timezone` header — so a list " \
              "shared with somebody in another city reads correctly for both of you; " \
              "each row names the zone it came back in. Forbidden (403) " \
              "if the caller is not a member of the list."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id: { type: "string", format: "uuid",
                            description: "The list whose todos to read — a `list_id` " \
                                         "from my_lists, verbatim." },
               },
               required: ["list_id"]
  output_schema type: "array",
                description: "The list's todos, oldest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    todo_id:             { type: "string", description: "uuid. Pass to complete_todo as `todo_id`." },
                    title:               { type: "string", description: "The todo text." },
                    done:                { type: "boolean", description: "Whether it has been completed." },
                    created_by_agent_id: { type: %w[string null], description: "The assistant that added it (attribution), or null when a human did." },
                    due_at:              { type: %w[string null], description: "The deadline as an ISO 8601 instant carrying YOUR declared zone's offset, or null when the todo has none. It is ONE moment: a second reader of this same list sees the same moment on their own clock." },
                    due_label:           { type: %w[string null], description: "The deadline said out loud, IN THE ZONE IT NAMES — e.g. \"Tue 8 Sep, 14:00 (Europe/Istanbul)\" — or null. This is the line to read back to your human; `due_at` carries the offset, and nobody says an offset out loud." },
                    timezone:            { type: "string", description: "The IANA zone these rows are rendered in: the one you declared in `Kiosk-Timezone`, or this household's own when you declared none." },
                  },
                  required: %w[todo_id title done created_by_agent_id due_at due_label timezone],
                }
  def list_todos
    ListAccess.member!(params[:list_id])
    render json: Todo.rows_on(params[:list_id])
  end

  kind :query
  reach :consented
  description "Return who else is on a list the caller is a member of, named the way they show " \
              "themselves to the household, and what each of them may do there — the answer a " \
              "collaborator needs before it shares the list further or removes anyone from it. " \
              "Forbidden (403) if the caller is not a member of the list."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id: { type: "string", format: "uuid",
                            description: "The list whose members to read — a `list_id` " \
                                         "from my_lists, verbatim." },
               },
               required: ["list_id"]
  output_schema type: "array",
                description: "The list's members, owners first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    account_id:   { type: "string", description: "uuid. Pass to remove_member as `account_id`." },
                    display_name: { type: "string", description: "How this member is named on the list — the name they chose, or a stable opaque `member-<hex>` when they have chosen none (every assistant-created account has). NEVER a login address, and there is no verb that turns it back into one." },
                    role:         { enum: Membership.roles.keys, description: "Their role on this list. The last owner cannot be removed." },
                  },
                  required: %w[account_id display_name role],
                }
  def list_members
    ListAccess.member!(params[:list_id])
    render json: Membership.rows_on(params[:list_id])
  end
end
