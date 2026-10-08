# frozen_string_literal: true

# Marks a todo on one of the principal's lists done.
class CompleteTodoOperation
  def self.call(todo_id:)
    todo = Todo.own.find_by(id: todo_id)
    unless todo
      raise Kiosk::Server::Errors::Forbidden.new("todo not on a list the authenticated principal is a member of",
                                                 hint: "You may only complete todos on lists you are a member of.")
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
