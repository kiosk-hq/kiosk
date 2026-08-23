# frozen_string_literal: true

# add_todo — a todo on a list the caller is a member of, stamped with the agent
# that added it. Reached from BOTH surfaces: the wire and the web UI's form.
class AddTodoOperation
  # @param agent_id [String, nil] the ACTING agent (kiosk.agents.id) —
  #   attribution in a shared space ("who added the tent? — Bob's assistant").
  #   nil for the human web surface, which has no agent — the column is nullable
  #   for exactly that reason.
  def self.call(agent_id:, list_id:, title:)
    # Membership BEFORE the title check: a non-member learns nothing about the
    # list from a title complaint.
    refusal = ListAccess.check(list_id)
    return refusal if refusal

    text = title.to_s
    return OperationResult.refused(code: "bad_request", message: "title required") if text.strip.empty?

    # `insert!`, not `create!`: `belongs_to :list` under `create!` would turn a
    # vanished list's InvalidForeignKey into a RecordInvalid — a 500 into a 400.
    # `.to_s` keeps an off-schema scalar's bytes (raw `true` would write "t").
    todo_id = Todo.insert!(
      { list_id: list_id, title: text, done: false, created_by_agent_id: agent_id },
      returning: %i[id],
    ).first["id"]

    OperationResult.ok({ "todo_id" => todo_id })
  end
end
