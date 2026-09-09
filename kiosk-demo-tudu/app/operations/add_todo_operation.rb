# frozen_string_literal: true

# add_todo — a todo on a list the caller is a member of, stamped with the agent
# that added it. Reached from BOTH surfaces: the wire and the web UI's form.
class AddTodoOperation
  # @param agent_id [String, nil] the ACTING agent (kiosk.agents.id) —
  #   attribution in a shared space ("who added the tent? — Bob's assistant").
  #   nil for the human web surface, which has no agent — the column is nullable
  #   for exactly that reason.
  # @param due_at [String, nil] an OPTIONAL deadline, as an RFC 3339 instant.
  #   The offset is REQUIRED and a value without one is refused rather than
  #   completed: "tomorrow at two" is resolved by the ASSISTANT, on the clock of
  #   the human who said it, before it ever reaches this wire. Completing it
  #   here would complete it on somebody else's clock — and on a SHARED list
  #   that somebody else is a real second reader.
  def self.call(agent_id:, list_id:, title:, due_at: nil)
    # Membership BEFORE the title check: a non-member learns nothing about the
    # list from a title complaint.
    refusal = ListAccess.check(list_id)
    return refusal if refusal

    text = title.to_s
    return OperationResult.refused(code: "bad_request", message: "title required") if text.strip.empty?

    due = nil
    if due_at.present?
      if ReaderClock.zoneless?(due_at)
        return OperationResult.refused(
          code:    "bad_request",
          message: "due_at #{due_at.to_s.inspect} names no time zone — a deadline is an INSTANT, " \
                   "so pass an ISO 8601 timestamp carrying its offset, e.g. " \
                   "\"2026-09-08T14:00:00+03:00\". Resolve «tomorrow at two» on the clock of the " \
                   "human who said it: whoever ELSE shares this list will read it on theirs, and a " \
                   "value with no offset means two different moments to the two of them.",
        )
      end

      due = begin
        ReaderClock.parse(due_at)
      rescue ArgumentError, TypeError
        return OperationResult.refused(
          code:    "bad_request",
          message: "invalid due_at #{due_at.to_s.inspect} — pass an ISO 8601 timestamp with an " \
                   "offset, e.g. \"2026-09-08T14:00:00+03:00\"",
        )
      end
    end

    # `insert!`, not `create!`: `belongs_to :list` under `create!` would turn a
    # vanished list's InvalidForeignKey into a RecordInvalid — a 500 into a 400.
    # `.to_s` keeps an off-schema scalar's bytes (raw `true` would write "t").
    todo_id = Todo.insert!(
      { list_id: list_id, title: text, done: false, created_by_agent_id: agent_id, due_at: due },
      returning: %i[id],
    ).first["id"]

    OperationResult.ok({ "todo_id" => todo_id })
  end
end
