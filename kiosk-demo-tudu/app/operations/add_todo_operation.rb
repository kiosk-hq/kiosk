# frozen_string_literal: true

# A todo on one of the principal's lists, attributed to the assistant that added
# it (nil for a human).
class AddTodoOperation
  def self.call(agent_id:, list_id:, title:, due_at: nil)
    ListAccess.member!(list_id)
    raise Kiosk::Server::Errors::BadRequest, "title required" if title.to_s.strip.empty?

    todo = Todo.create!(list_id: list_id, title: title, created_by_agent_id: agent_id, due_at: due_at)

    Kiosk::Server::Events.emit(
      topic: :todo, subject: list_id,
      identity_scope: Membership.account_ids_on(list_id),
      data: { "todo_id" => todo.id, "title" => todo.title, "done" => false, "action" => "added" },
    )

    { todo_id: todo.id }
  end
end
