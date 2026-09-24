# frozen_string_literal: true

# complete_todo — mark a todo done, but only if the caller is a member of the
# todo's list. Reached from the wire and from the web UI's "Done" button.
class CompleteTodoOperation
  # This verb takes no `list_id`, so it never passes through {ListAccess}: the
  # membership test is folded into the write, against the todo's list.
  def self.call(todo_id:)
    # `complete_todo` declares `todo_id` with `format: "uuid"`, so on the wire
    # the argument validation has already refused a malformed one. The door this
    # check is for is the web UI's "Done" button, which hands over a raw URL
    # segment ({TodosController#complete}) with no schema anywhere in front of
    # it — see {ListAccess.check} for what a missing shape check costs there.
    unless Kiosk::UuidCheck.valid?(todo_id)
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

    # The list and the title are re-read ONLY for the event: the answer below
    # still echoes the id verbatim. `pick` is one statement and unscoped by
    # principal on purpose — the membership test above has already run, and the
    # row is the one it just wrote.
    list_id, title = Todo.where(id: todo_id).pick(:list_id, :title)
    if list_id
      Kiosk::Server::Events.emit(
        topic: :todo, subject: list_id,
        identity_scope: Membership.account_ids_on(list_id),
        data: { "todo_id" => todo_id, "title" => title, "done" => true, "action" => "completed" },
      )
    end

    # The id is echoed back VERBATIM as the caller sent it, never re-read.
    OperationResult.ok({ "todo_id" => todo_id, "done" => true })
  end
end
