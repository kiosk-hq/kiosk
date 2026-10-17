# frozen_string_literal: true

# Todo lists.
class Kiosk::ListsController < ApplicationController
  include Kiosk::Handler

  kind :query
  reach :consented
  description "The lists the signed-in member is on, as owner or member. Once the human picks one, " \
              "`list_todos` reads it and `add_todo` adds to it."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The member's lists, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    list_id: { type: "string", description: "Pass to list_todos / list_members / add_todo / invite / remove_member as `list_id`." },
                    title:   { type: "string", description: "The list title." },
                    role:    { enum: Membership.roles.keys, description: "Your role on this list; `invite` and `remove_member` are owner-only." },
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

  kind :action
  description "Create a todo list; the signed-in member becomes its owner."
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
                  list_id: { type: "string", description: "Pass to list_todos / add_todo / invite as `list_id`." },
                },
                required: ["list_id"]
  example_params({ title: "Hike" })
  example_row({ list_id: "d4e5f6a7-8b9c-4d0e-9f1a-2b3c4d5e6f70" })
  def create_list
    render json: CreateListOperation.call(member_id: kiosk_identity.user_id, title: params[:title])
  end
end
