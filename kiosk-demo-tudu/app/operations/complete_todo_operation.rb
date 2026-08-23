# frozen_string_literal: true

# complete_todo — mark a todo done, but only if the caller is a member of the
# todo's list. Reached from the wire and from the web UI's "Done" button.
class CompleteTodoOperation
  # This verb takes no `list_id`, so it never passes through {ListAccess}: the
  # membership test is folded into the write, against the todo's list.
  def self.call(todo_id:)
    # The one wire-supplied id in tudu with no other guard in front of it
    # (K-581/K-582) — see {ListAccess.check} for why the shape check matters.
    unless UuidCheck.valid?(todo_id)
      return OperationResult.refused(
        code:    "bad_request",
        message: "todo_id #{todo_id.to_s.inspect} is not a uuid",
        hint:    "Pass a `todo_id` from list_todos, verbatim.",
      )
    end

    # ONE statement: the membership test and the write cannot be separated by
    # another transaction, and the ROW COUNT is the access answer — zero rows
    # means "not yours", so probing cannot enumerate which todo ids exist.
    # `update_all` (not `update!`) keeps that and skips validations; `update!`
    # would need a `find`, whose RecordNotFound renders 404 for a todo that today
    # answers `forbidden`. The `IN (SELECT list_id FROM memberships …)` predicate
    # is exact because `memberships.list_id` is NOT NULL: the subquery can never
    # yield the NULL that makes `IN` return unknown instead of false.
    completed = Todo.where(id: todo_id)
                    .where(list_id: Membership.of_current_principal.select(:list_id))
                    .update_all(done: true, updated_at: Time.current)

    if completed.zero?
      return OperationResult.refused(
        code:    "forbidden",
        message: "todo not on a list the authenticated principal is a member of",
        hint:    "You may only complete todos on lists you are a member of.",
      )
    end

    # The id is echoed back VERBATIM as the caller sent it, never re-read.
    OperationResult.ok({ "todo_id" => todo_id, "done" => true })
  end
end
