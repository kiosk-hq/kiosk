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
  #
  #   WHERE THAT REFUSAL COMES FROM ON THE WIRE: `add_todo` declares `due_at`
  #   with `format: "date-time"`, which is RFC 3339 and so carries the offset
  #   demand in the DECLARATION, and a verb's arguments are validated before any
  #   handler runs. An assistant therefore meets the operator's own typed 400
  #   naming the argument, and the two refusals below are the second door — for
  #   a caller with no schema in front of it (a console, a rake task, a web form
  #   an operator wires onto this Operation). `rake demo:clock_spec` drives both
  #   of them directly; `demo:collab` asserts the wire's.
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
                   "#{example_due_at.inspect}. Resolve «tomorrow at two» on the clock of the " \
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
                   "offset, e.g. #{example_due_at.inspect}",
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

  # THE ONE «here is a value that works» INSTANT this demo publishes, read from
  # two places that must not disagree: the catalogue, which carries it as the
  # `due_at` of `add_todo`'s `example_params` (a resolvable slot, so the served
  # bytes re-resolve rather than freeze at boot), and the two `due_at` refusals
  # above, which quote it back as the shape to retry.
  #
  # RESOLVED, NOT WRITTEN DOWN. A calendar literal in shipped code ages: it goes
  # on saying «e.g. 2026-09-08» long after that day is gone, and an assistant
  # copying it sends a deadline in the past. Tomorrow at 14:00, on this
  # household's own clock, is always a plausible one.
  #
  # It carries an OFFSET because that is the half the sentence is about: the
  # example must be a value this verb would ACCEPT, and a zoneless one is
  # refused.
  #
  # @return [String] an ISO 8601 instant carrying an offset
  def self.example_due_at
    ReaderClock.default_zone.now.advance(days: 1).change(hour: 14).iso8601
  end
end
