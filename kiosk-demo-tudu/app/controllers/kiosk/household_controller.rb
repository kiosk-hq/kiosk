# frozen_string_literal: true

# tudu's READ surface: the four verbs an assistant reaches with
# `POST /kiosk/query`. Kiosk ships a MIXIN, not a base class — the superclass is
# this app's own ApplicationController, and `include Kiosk::Query` is the whole
# contract. Each class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot see.
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the write half lives next door in
# Kiosk::TodoListsController. tudu is the demo where that split BITES: the
# membership guard is called from two queries here and three actions there, so
# it could belong to neither class. It is split instead: the access DECISION is
# `Membership.reachable?` (a model method, no request in it) and the HTTP
# refusal is {KioskMembershipGate} (an ordinary Rails concern, included by both
# halves). Neither copy of anything is duplicated.
#
# Access here is MEMBERSHIP-based, not owner-scoped — the whole point of this
# demo. A list is reachable by every account with a `memberships` row for it,
# and a non-member gets 403 rather than 404 so probing can't enumerate ids.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate and the GUC-scoped transaction live. A route drawn straight here
# would bypass all three, and the mixin answers such a request 404.
class Kiosk::HouseholdController < ApplicationController
  include Kiosk::Query
  include KioskMembershipGate

  # whoami — the authenticated principal + the acting agent. Handy first call
  # for an assistant orienting itself; also proves the attribution wiring.
  #
  # Both values come from `kiosk_identity`, the identity the wire resolved for
  # this request. They used to be two `SELECT` round-trips to the GUCs
  # (`kiosk.current_user_id()` and the raw `app.current_agent_id` setting)
  # through a pair of top-level `def`s that monkeypatched Object — the K-701
  # shape, which existed only because a boot-time `register` block had no other
  # way to reach request state. A controller action simply HAS it, and the two
  # sources cannot disagree: SessionContext SET LOCALs those very GUCs FROM this
  # identity at the top of this same request, which is why the description below
  # is unchanged — it names the principal the answer means, not the round-trip
  # it no longer takes.
  description "Return the authenticated principal: { account_id, agent_id, handle } " \
              "resolved from the Kiosk GUC (kiosk.current_user_id / current_agent_id)."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # A ONE-ROW array: this is a query and a query answers with rows. `agent_id`
  # is null when the principal is a human web session rather than an assistant,
  # and `handle` is null when the account has no email on file — both are real
  # states of this demo's own tables, not defensive nulls.
  output_schema type: "array",
                description: "Exactly one row: the authenticated principal.",
                minItems: 1, maxItems: 1,
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    account_id: { type: "string", description: "uuid — the principal, from kiosk.current_user_id(). Pass it to remove_member as `account_id`." },
                    agent_id:   { type: %w[string null], description: "The acting assistant, or null when a human session is calling." },
                    handle:     { type: %w[string null], description: "The account's email handle, or null when it has none." },
                  },
                  required: %w[account_id agent_id handle],
                }
  def whoami
    account_id = kiosk_identity.user_id
    render json: [{ "account_id" => account_id,
                    "agent_id"   => kiosk_identity.agent_id,
                    "handle"     => User.where(id: account_id).pick(:email) }]
  end

  # my_lists — the lists the caller is a MEMBER of (owner OR member), via the
  # memberships join. Membership-based, not owner-scoped: the caller sees lists
  # it was invited into as well as its own. Provider-controlled WHERE;
  # un-bypassable (the agent supplies no filter at all).
  description "List the todo lists the authenticated principal is a member of " \
              "(owner or member), with the caller's role on each. Membership-based " \
              "access — includes lists the caller was invited into. Takes no " \
              "parameters and returns all the caller's lists (small; not paginated); " \
              "each row carries list_id, title, and the caller's role (owner|member). " \
              "Pass a list_id to list_todos / add_todo."
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
                    role:    { enum: %w[owner member], description: "The CALLER's role on this list — `invite` and `remove_member` are owner-only." },
                  },
                  required: %w[list_id title role],
                }
  example_params({})
  example_row({
    list_id: "d4e5f6a7-8b9c-4d0e-9f1a-2b3c4d5e6f70", title: "Flat 3B", role: "owner",
  })
  # The rows themselves are {List.reachable_rows} — a MODEL PROJECTION, because
  # the human web UI's `/lists` page publishes exactly these rows and used to get
  # them by dispatching a synthetic Rack sub-request at this very action (T-082).
  # The wire is for assistants; the page now reads the same projection directly, so
  # there is one definition of a list row instead of two surfaces to keep in
  # agreement. The membership predicate inside it is
  # `Membership.of_current_principal` — a scope, not a Ruby comparison; see the
  # long note on it for why that one fragment stays SQL.
  def my_lists
    render json: List.reachable_rows
  end

  # list_todos(list_id) — membership-gated: 403 unless the caller is a member.
  # Returns the list's todos with attribution (created_by_agent_id).
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
  # too (T-082). Both doors run the SAME gate and then the SAME projection, which
  # is what stops the page and the verb from drifting apart.
  def list_todos
    return unless kiosk_membership_gate(params[:list_id])

    render json: Todo.rows_on(params[:list_id])
  end

  # list_members(list_id) — membership-gated; returns the members + roles so a
  # collaborator can see who else is on the list.
  description "Return the members of a list the caller is a member of: " \
              "{ account_id, handle, role }. Forbidden (403) if the caller is " \
              "not a member of the list."
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
                    account_id: { type: "string", description: "uuid. Pass to remove_member as `account_id`." },
                    handle:     { type: %w[string null], description: "The member's email handle, or null when the account has none." },
                    role:       { enum: %w[owner member], description: "Their role on this list. The last owner cannot be removed." },
                  },
                  required: %w[account_id handle role],
                }
  # Gate, then {Membership.rows_on} — the projection the web page's member list
  # renders too (T-082).
  def list_members
    return unless kiosk_membership_gate(params[:list_id])

    render json: Membership.rows_on(params[:list_id])
  end
end
