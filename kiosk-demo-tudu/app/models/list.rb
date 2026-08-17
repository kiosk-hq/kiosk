# frozen_string_literal: true

# A todo list. `account_id` is the OWNER account (users.id) — but access is NOT
# owner-scoped: a list is reachable by every account with a `memberships` row for
# it. The owner is just the member whose role is 'owner' (invite/remove_member
# authority). The load-bearing isolation predicate is `Membership.reachable?` —
# a `memberships` row for this list whose `account_id` is
# `kiosk.current_user_id()` — reached by every list-scoped verb through
# {ListAccess}: the write half's Operations consult it directly, the read half's
# handlers through {KioskMembershipGate}.
class List < ApplicationRecord
  belongs_to :account, class_name: "User", foreign_key: :account_id, inverse_of: :lists
  has_many :memberships, dependent: :destroy
  has_many :todos, dependent: :destroy
  has_many :invites, dependent: :destroy

  validates :title, presence: true

  # ── THE PROJECTION BOTH OF tudu's DOORS READ (T-082) ───────────────────────
  # The lists the current principal is a member of, in the shape `my_lists`
  # publishes: one string-keyed row per list, with the caller's role on it.
  #
  # WHY IT IS HERE AND NOT IN THE HANDLER, which is where it lived until T-082.
  # tudu is the only demo with a human web UI over the same domain, and its
  # `/lists` page needs exactly these rows. It used to get them by dispatching a
  # synthetic Rack sub-request at the query handler — the human UI travelling
  # through the WIRE dispatcher, which is the property T-082 exists to remove: the
  # wire is for assistants. Now the handler renders this and the page renders
  # this, so there is ONE definition of what a list row is and no drift to keep in
  # agreement. It is a PROJECTION, which is a model's job (Phil, 2026-08-17: models
  # stay persistence + query scoping) — an Operation is for writes.
  #
  # THE AUTHORITY IS NOT A PARAMETER, and that is deliberate — the opposite of
  # getgrocery's `Order.settling(settlements)`, where the two surfaces are
  # entitled to DIFFERENT rows and the scope must therefore be handed in. Here
  # both doors mean the same principal and read it the same way: from
  # `kiosk.current_user_id()`, the GUC SessionContext SET LOCALs around the
  # request on the wire path and around {KioskSessionable#kiosk_as_human} on the
  # web path. Neither caller can pass a different one, which is exactly the
  # property that makes this un-bypassable.
  #
  # The column ALIASES the old `SELECT` carried (`l.id AS list_id`) are the `map`
  # below: `pluck` returns bare tuples, so the published row shape is written out
  # rather than being a side effect of how the SELECT was spelled. The two
  # orderings are unchanged, tiebreaker included — `l.id` is what keeps two lists
  # created in the same microsecond from swapping places between runs.
  #
  # @return [Array<Hash>] string-keyed, because the wire renders this straight to
  #   JSON and the web view reads `l["title"]` out of the same object — one shape
  #   has to serve both readers ({OperationResult} makes the same choice for the
  #   write half, and for the same reason).
  def self.reachable_rows
    joins(:memberships).merge(Membership.of_current_principal)
      .order(created_at: :desc, id: :asc)
      .pluck(:id, :title, Membership.arel_table[:role])
      .map { |id, title, role| { "list_id" => id, "title" => title, "role" => role } }
  end
end
