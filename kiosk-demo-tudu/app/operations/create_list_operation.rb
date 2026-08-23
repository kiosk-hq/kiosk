# frozen_string_literal: true

# create_list — a new list owned by the authenticated principal, plus the owner
# membership that makes it reachable, in one transaction. Reached from BOTH
# surfaces: `POST /kiosk/create_list` and the web UI's "New list" form — which is
# the whole reason it is an Operation and not a controller method.
class CreateListOperation
  # @param principal_id [String] the account the wire (or the Devise session)
  #   resolved. NEVER an argument off the request: `account_id`/`owner_id`/`id`
  #   are never read out of the params, and a forged one does not even reach here
  #   — `create_list` publishes `additionalProperties: false` with `title` as its
  #   only property, so the wire answers a typed 400. That is the outer guard;
  #   this is the one that would still hold if the schema were loosened.
  #
  #   An INSERT is the one place the principal must be spelled in Ruby: a READ
  #   hides it in `Membership.of_current_principal`'s WHERE predicate, an INSERT
  #   has none. Moving the column DEFAULT to `kiosk.current_user_id()` would keep
  #   the database the authority; that is a migration.
  def self.call(principal_id:, title:)
    text = title.to_s
    return OperationResult.refused(code: "bad_request", message: "title required") if text.strip.empty?

    # JOINS the transaction Kiosk::Server::SessionContext already opened around
    # the request (the GUCs are SET LOCAL in it), so it opens no second one. The
    # list and its owner membership still land together or not at all.
    list_id = List.transaction do
      id = List.insert!({ account_id: principal_id, title: text }, returning: %i[id]).first["id"]
      # `insert!`, NOT `create!`, and the reason is a wire answer rather than
      # taste: `create!` runs `belongs_to :account`'s required-by-default
      # validation, so a principal with no `users` row would raise RecordInvalid
      # (422 → `bad_request`) where the InvalidForeignKey Postgres raises is a 500.
      Membership.insert!({ list_id: id, account_id: principal_id, role: Membership::OWNER })
      id
    end

    OperationResult.ok({ "list_id" => list_id })
  end
end
