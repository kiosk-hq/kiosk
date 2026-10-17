# frozen_string_literal: true

# A todo on one of the member's lists, attributed to the assistant that added
# it (nil for a human). Returns the todo.
class AddTodoOperation
  def self.call(agent_id:, list_id:, title:, due_at: nil)
    ListAccess.member!(list_id)

    todo = Todo.create!(list_id: list_id, title: title, created_by_agent_id: agent_id, due_at: due_at)

    Kiosk::Server::Events.emit(
      topic: :todo, subject: list_id,
      identity_scope: Membership.account_ids_on(list_id),
      data: { "todo_id" => todo.id, "title" => todo.title, "done" => false, "action" => "added" },
    )

    todo
  end
end
