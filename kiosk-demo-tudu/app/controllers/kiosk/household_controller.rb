# frozen_string_literal: true

# tudu's READ surface: the four verbs an assistant reaches with
# `GET /kiosk/<query-name>` — one endpoint per verb (protocol 0.4), arguments in
# the query string, and the success body IS the rows array. Kiosk ships a MIXIN,
# not a base class: `include Kiosk::Handler` is the whole contract and a macro is
# claimed by the NEXT `def`, so a method with no macros above it is a helper the
# wire cannot see. `kind :query` is what puts a declaration on `GET`.
#
# Access here is MEMBERSHIP-based, not owner-scoped — the whole point of this
# demo. A list is reachable by every account with a `memberships` row for it, and
# a non-member gets 403 rather than 404 so probing can't enumerate ids. The
# decision is `Membership.reachable?` (no request in it); the HTTP refusal is
# {KioskMembershipGate}, shared with the write half in Kiosk::TodoListsController.
#
# NOT ROUTABLE: config/routes.rb draws nothing here. Handlers are reached only
# through the wire, where authentication, the registration PoW gate and the
# GUC-scoped transaction live; the mixin answers a direct request 404.
class Kiosk::HouseholdController < ApplicationController
  include Kiosk::Handler
  include KioskMembershipGate

  # whoami — the authenticated principal + the acting agent. Handy first call for
  # an assistant orienting itself; also proves the attribution wiring. Both values
  # come from `kiosk_identity` and cannot disagree with the GUCs: SessionContext
  # SET LOCALs those FROM this identity at the top of this same request.
  kind :query
  description "Return who this call is authenticated as: the account the operator resolved for the " \
              "request, the assistant acting on that account's behalf when one is, and the display " \
              "name that account carries in front of the people it shares lists with. A useful first " \
              "call for an assistant orienting itself, and the proof that attribution is wired — " \
              "everything this origin writes is attributed to exactly this pair."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # A ONE-ROW array: this is a query and a query answers with rows. `agent_id` is
  # null when a human web session is calling rather than an assistant — a real
  # state of this demo's tables, not a defensive null. `display_name` is NOT
  # nullable and is NEVER an address (K-950): {User.public_name} answers a blank
  # name with an opaque `member-<hex>` over the account UUID.
  output_schema type: "array",
                description: "Exactly one row: the authenticated principal.",
                minItems: 1, maxItems: 1,
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    account_id:   { type: "string", description: "uuid — the principal, from kiosk.current_user_id(). Pass it to remove_member as `account_id`." },
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

  # my_lists — the lists the caller is a MEMBER of (owner OR member): a list it
  # was invited into is listed alongside its own. The agent supplies no filter.
  #
  # `reach :consented` (K-949, ADR-0028): a row here may be a list somebody else
  # owns, and what admits it is an act by the human whose data it is — an owner
  # minted a single-use invite, `accept_invite` turned it into a `memberships`
  # row. That row IS the authorising artefact, and every verb below reads it.
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
                    # `Membership::ROLES`, not a literal (K-946): the model
                    # VALIDATES against that constant, so a fourth role added
                    # there would otherwise leave both published schemas wrong.
                    role:    { enum: Membership::ROLES, description: "The CALLER's role on this list — `invite` and `remove_member` are owner-only." },
                  },
                  required: %w[list_id title role],
                }
  example_params({})
  example_row({
    list_id: "d4e5f6a7-8b9c-4d0e-9f1a-2b3c4d5e6f70", title: "Flat 3B", role: "owner",
  })
  # The rows are {List.reachable_rows} — a MODEL PROJECTION, because the web UI's
  # `/lists` page publishes exactly these rows (T-082): one definition of a list
  # row, not two surfaces to keep in agreement. Its membership predicate is
  # `Membership.of_current_principal`, a scope rather than a Ruby comparison.
  def my_lists
    render json: List.reachable_rows
  end

  # list_todos(list_id) — membership-gated: 403 unless the caller is a member.
  # `reach :consented`, same artefact; §7.2 form 2 still applies to everything
  # outside that reach — a non-member gets 403, not a filtered 200.
  kind :query
  reach :consented
  description "Return the todos on a list the caller is a member of, each with " \
              "its completion state and the agent that added it. Forbidden (403) " \
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
                  },
                  required: %w[todo_id title done created_by_agent_id],
                }
  # Gate, then {Todo.rows_on} — the projection tudu's `/lists/:id` page renders
  # too (T-082): both doors run the same gate and then the same projection.
  def list_todos
    return unless kiosk_membership_gate(params[:list_id])

    render json: Todo.rows_on(params[:list_id])
  end

  # list_members(list_id) — membership-gated; the members + roles, so a
  # collaborator can see who else is on the list. The most obviously
  # cross-principal verb tudu has: the rows ARE other accounts.
  #
  # WHAT THE CONSENT DOES NOT BUY (K-950): the roster, yes; the members' LOGIN
  # ADDRESSES, no. §7.2's prohibition binds every reach, `consented` included —
  # consent to share a list is not consent to publish an email address.
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
                    # `Membership::ROLES` — same reason as `my_lists` above (K-946).
                    role:         { enum: Membership::ROLES, description: "Their role on this list. The last owner cannot be removed." },
                  },
                  required: %w[account_id display_name role],
                }
  # Gate, then {Membership.rows_on} — the projection the web page's member list
  # renders too (T-082).
  def list_members
    return unless kiosk_membership_gate(params[:list_id])

    render json: Membership.rows_on(params[:list_id])
  end
end
