# frozen_string_literal: true

# add_todo — a todo on a list the caller is a member of, stamped with the agent
# that added it.
#
# Reached from BOTH surfaces: the wire, and the web UI's "New todo" form.
class AddTodoOperation
  # @param agent_id [String, nil] the ACTING agent (kiosk.agents.id) —
  #   attribution in a shared space ("who added the tent? — Bob's assistant").
  #   nil for the human web surface, which has no agent, and the column is
  #   nullable for exactly that reason.
  def self.call(agent_id:, list_id:, title:)
    # Membership BEFORE the title check, the order the handler has always used:
    # a non-member learns nothing about the list from a title complaint.
    refusal = ListAccess.check(list_id)
    return refusal if refusal

    text = title.to_s
    return OperationResult.refused(code: "bad_request", message: "title required") if text.strip.empty?

    # `insert!` for the CreateListOperation reason: `belongs_to :list` under
    # `create!` would turn the InvalidForeignKey of a vanished list into a
    # RecordInvalid, i.e. a 500 into a 400. `.to_s` on the title is not
    # cosmetic either — it is what keeps an off-schema scalar rendering the same
    # bytes it always has: `conn.quote(true)` produced `'true'`, and handing the
    # raw `true` to ActiveRecord's string type would write "t" instead.
    todo_id = Todo.insert!(
      { list_id: list_id, title: text, done: false, created_by_agent_id: agent_id },
      returning: %i[id],
    ).first["id"]

    OperationResult.ok({ "todo_id" => todo_id })
  end
end
