# frozen_string_literal: true

# The join row that grants an account access to a list. This is tudu's
# many-to-many "isolation grows up" surface: every list/todo query & action
# checks a membership EXISTS for the GUC principal, and `remove_member` DELETEs
# one to cut access instantly. `role` is owner|member — the owner (there is at
# least one) holds invite/remove authority.
class Membership < ApplicationRecord
  OWNER  = "owner"
  MEMBER = "member"
  ROLES  = [OWNER, MEMBER].freeze

  belongs_to :list
  belongs_to :account, class_name: "User", foreign_key: :account_id, inverse_of: :memberships

  validates :role, inclusion: { in: ROLES }
  validates :account_id, uniqueness: { scope: :list_id }

  # ── THE isolation predicate ────────────────────────────────────────────────
  # When tudu's handlers stopped writing SQL (K-654) this is the one fragment
  # that deliberately did NOT become a Ruby comparison, for the reason the
  # philslist pilot settled (see Listing#owned_by_current_principal).
  #
  # `kiosk.current_user_id()` is a STABLE Postgres function reading the
  # transaction-local GUC `app.current_user_id`, which kiosk-server's
  # SessionContext sets with `SET LOCAL` — from the identity the wire resolved
  # (or, on tudu's second door, the signed-in human) inside the very transaction
  # the request runs in — and which evaporates at COMMIT. A `where(account_id:
  # <a ruby value>)` would be just as unforgeable here; what it would cost is
  # the part that generalises. Spec §7 makes DB-enforced identity scoping a
  # MUST, and this is the seam where the app-layer predicate and the optional
  # DB-layer RLS policy are literally the same expression. A demo is the
  # reference other operators copy.
  #
  # `Arel.sql` over a frozen literal rather than an interpolated string: there
  # is no caller-controlled value anywhere in this fragment. That is what makes
  # it exempt from the no-raw-SQL rule rather than an exception to it.
  scope :of_current_principal, lambda {
    where(arel_table[:account_id].eq(Arel.sql("kiosk.current_user_id()")))
  }

  # THE ACCESS DECISION, and it lives here rather than in a controller or an
  # Operation because it is a fact about the domain, not about a request: "may
  # the current principal reach this list, and (optionally) does it own it?"
  # It takes no request, renders nothing and answers true/false, so it can be
  # exercised from a console or a model test with nothing but the GUC set. Its
  # REFUSAL — the sentence a caller is told — is not here; that belongs to
  # {ListAccess}, because what to say is a fact about a caller.
  #
  # The principal is NOT a parameter: the scope above reads it from
  # `kiosk.current_user_id()`, the GUC SessionContext SET LOCALs around the
  # whole request on both of tudu's doors. A caller cannot pass a different one,
  # which is the property that makes this un-bypassable.
  #
  # Shape is NOT checked here, and the consequence CHANGED with K-654. It used
  # to interpolate the id into a `::uuid` cast, so a malformed value raised
  # InvalidTextRepresentation; `where(list_id:)` instead casts an unparseable
  # value to NULL and simply answers false. Either way {ListAccess} checks the
  # shape FIRST and answers 400, so nothing reaches here malformed — but the
  # guard is now the only thing standing between a typo and a 403, which is
  # why its note says so at length.
  #
  # @param list_id [String] a canonical uuid (see UuidCheck)
  # @param require_owner [Boolean] tighten to role='owner' (invite/remove authority)
  # @return [Boolean]
  def self.reachable?(list_id, require_owner: false)
    scope = of_current_principal.where(list_id: list_id)
    scope = scope.where(role: OWNER) if require_owner
    scope.exists?
  end
end
