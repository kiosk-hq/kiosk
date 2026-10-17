# frozen_string_literal: true

# Marks a todo on one of the member's lists done.
class CompleteTodoOperation
  def self.call(todo_id:)
    todo = Todo.own.find_by(id: todo_id)
    unless todo
      raise Kiosk::Server::Errors::Forbidden.new("todo is not on a list you are a member of",
                                                 hint: "Use a todo from list_todos.")
    end

    todo.update!(done: true)

    Kiosk::Server::Events.emit(
      topic: :todo, subject: todo.list_id,
      identity_scope: Membership.account_ids_on(todo.list_id),
      data: { "todo_id" => todo.id, "title" => todo.title, "done" => true, "action" => "completed" },
    )

    { todo_id: todo_id, done: true }
  end
end
