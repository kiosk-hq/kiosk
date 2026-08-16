# frozen_string_literal: true

# create_list — a new list owned by the authenticated principal, plus the owner
# membership that makes it reachable, in one transaction.
#
# Reached from BOTH surfaces: `POST /kiosk/run {name: "create_list"}` and the
# human web UI's "New list" form. That is the whole reason it is an Operation
# and not a controller method — before this, the web form reached the wire
# handler by dispatching a synthetic Rack sub-request at it.
class CreateListOperation
  # @param principal_id [String] the account the wire (or the Devise session)
  #   resolved. NEVER an argument off the request: `create_list` deliberately
  #   IGNORES a forged `account_id`/`owner_id`/`id` in the body, and it can do
  #   that precisely because the value is passed in from the identity rather
  #   than read out of the params.
  #
  #   An INSERT is the one place the principal must be spelled in Ruby. Every
  #   READ scopes with `Membership.of_current_principal`, which never names the
  #   principal at all because a WHERE has a predicate to hide it in; an INSERT
  #   has no predicate, so it must supply the value. Both are un-forgeable for
  #   the same reason — the identity is resolved from the Rack env the wire
  #   built, which no request argument can write — but only the first keeps the
  #   database as the authority. Moving the column DEFAULT to
  #   `kiosk.current_user_id()` would close the gap; that is a migration, not
  #   part of a handler conversion (the atablefor note, unchanged).
  def self.call(principal_id:, title:)
    text = title.to_s
    return OperationResult.refused(code: "bad_request", message: "title required") if text.strip.empty?

    # This `transaction` JOINS the one Kiosk::Server::SessionContext already
    # opened around the request (the GUCs are SET LOCAL in it) — on the wire
    # path and on the web path alike — so it opens no second transaction. The
    # list and its owner membership still land together or not at all, which is
    # the invariant it is written for.
    list_id = List.transaction do
      id = List.insert!({ account_id: principal_id, title: text }, returning: %i[id]).first["id"]
      # `insert!`, NOT `create!`, and the reason is a wire answer rather than
      # taste. `create!` interposes validations, and `belongs_to :account` is
      # required by default — so a principal with no `users` row would turn the
      # `ActiveRecord::InvalidForeignKey` Postgres raises (unmapped in
      # `rescue_responses`, so re-raised and wrapped `action_failed`/500, which
      # is what the raw INSERT did) into a `RecordInvalid`, which Rails maps to
      # 422 and the handler mixin's `rescue_from` floor renders as
      # `bad_request`. A 500 silently becoming a 400 for an unrelated input is
      # exactly the class of change this conversion must not make.
      Membership.insert!({ list_id: id, account_id: principal_id, role: Membership::OWNER })
      id
    end

    OperationResult.ok({ "list_id" => list_id })
  end
end
