# frozen_string_literal: true

# complete_todo — mark a todo done, but only if the caller is a member of the
# todo's list.
#
# Reached from BOTH surfaces: the wire, and the web UI's "Done" button.
class CompleteTodoOperation
  # This verb takes no `list_id`, so it never passes through {ListAccess} —
  # the membership test has to be folded into the write itself, against the
  # list the todo belongs to.
  def self.call(todo_id:)
    # K-581/K-582: the one wire-supplied id in tudu with no other guard in
    # front of it. See {ListAccess.check} for why the shape check got MORE
    # load-bearing once the SQL became ActiveRecord.
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
    #
    # `update_all` (not `update!`) keeps that single-statement property and
    # skips validations exactly as the raw UPDATE did. It also raises nothing:
    # `update!` would need a `find` first, and `find` raises RecordNotFound,
    # which Rails maps to 404 — the mixin's `rescue_from` floor would then
    # answer `not_found` for a todo that today answers `forbidden`.
    #
    # The membership predicate was a correlated `EXISTS (… WHERE
    # memberships.list_id = todos.list_id AND account_id =
    # kiosk.current_user_id())` and is now `list_id IN (SELECT list_id FROM
    # memberships WHERE account_id = kiosk.current_user_id())`. Same answer, and
    # provably so rather than by hand-waving: `memberships.list_id` is NOT NULL,
    # so the subquery can never yield the NULL that makes `IN` return unknown
    # instead of false.
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

    # The id is echoed back VERBATIM as the caller sent it, which is what the
    # raw handler did — it never read the id back out of the database.
    OperationResult.ok({ "todo_id" => todo_id, "done" => true })
  end
end
