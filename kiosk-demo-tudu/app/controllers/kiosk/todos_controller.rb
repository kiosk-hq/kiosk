# frozen_string_literal: true

# The todos on a list.
class Kiosk::TodosController < ApplicationController
  include Kiosk::Handler

  topic :todo do
    reach :consented
    description "A todo on a list you can reach was `added` or `completed`, by any member or in the browser."
    payload_schema type: "object", additionalProperties: false,
                   properties: { todo_id: { type: "string", format: "uuid" },
                                 title:   { type: "string" },
                                 done:    { type: "boolean" },
                                 action:  { enum: %w[added completed] } },
                   required: %w[todo_id done action]
    example todo_id: "7f2a1b3c-4d5e-4a6b-8c9d-0e1f2a3b4c5d", title: "Book campsite", done: false, action: "added"
    example todo_id: "7f2a1b3c-4d5e-4a6b-8c9d-0e1f2a3b4c5d", title: "Book campsite", done: true, action: "completed"
    subject_reachable ->(list_id, identity) { Membership.readable_by?(list_id, identity.user_id) }
  end

  kind :query
  reach :consented
  description "The todos on a list you are on. Deadlines are rendered in the zone you declare in " \
              "`Kiosk-Timezone`, else in the household's."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id: { type: "string", format: "uuid", description: "A `list_id` from my_lists." },
               },
               required: ["list_id"]
  output_schema type: "array",
                description: "The list's todos, oldest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    todo_id:             { type: "string", description: "Pass to complete_todo as `todo_id`." },
                    title:               { type: "string", description: "The todo text." },
                    done:                { type: "boolean", description: "Whether it is done." },
                    created_by_agent_id: { type: %w[string null], description: "The assistant that added it, or null when a human did." },
                    due_at:              { type: %w[string null], description: "The deadline at your zone's offset, or null." },
                    due_label:           { type: %w[string null], description: "The deadline to read out to your human, e.g. \"Tue 8 Sep, 14:00 (Europe/Istanbul)\", or null." },
                    timezone:            { type: "string", description: "The IANA zone these rows are rendered in." },
                  },
                  required: %w[todo_id title done created_by_agent_id due_at due_label timezone],
                }
  def list_todos
    ListAccess.member!(params[:list_id])
    render json: Todo.rows_on(params[:list_id])
  end

  kind :action
  reach :consented
  description "Add a todo to a list you are on. The todo records which assistant added it."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id: { type: "string", format: "uuid", description: "A `list_id` from my_lists." },
                 title:   { type: "string", minLength: 1, description: "The todo text." },
                 due_at:  { type: "string", format: "date-time",
                            description: "The deadline, with its offset. Resolve «tomorrow at two» on the " \
                                         "clock of the human who said it." },
               },
               required: ["list_id", "title"]
  output_schema type: "object",
                description: "The added todo.",
                additionalProperties: false,
                properties: {
                  todo_id: { type: "string", description: "Pass to complete_todo as `todo_id`." },
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
  description "Mark a todo on a list you are on as done."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 todo_id: { type: "string", format: "uuid", description: "A `todo_id` from list_todos." },
               },
               required: ["todo_id"]
  output_schema type: "object",
                description: "The completed todo.",
                additionalProperties: false,
                properties: {
                  todo_id: { type: "string", description: "The completed todo." },
                  done:    { const: true, description: "Always true." },
                },
                required: %w[todo_id done]
  def complete_todo
    render json: CompleteTodoOperation.call(todo_id: params[:todo_id])
  end
end
