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
  # The one predicate in this demo deliberately written as SQL rather than as a
  # Ruby comparison. Why:
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
    # Off the wire there is no principal, so this predicate would be `= NULL`
    # and answer nothing at all; refuse instead of returning a plausible zero.
    Kiosk::Server::SessionContext.require_open!
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
  # Shape is NOT checked here, and that is load-bearing: `where(list_id:)` casts
  # an unparseable value to NULL and simply answers false — it never raises, so
  # a malformed id reads here as a foreign one. {ListAccess} checks the shape
  # FIRST and answers 400, so nothing reaches here malformed. On the wire the
  # verb's own `format: "uuid"` has already answered; on the WEB door, which has
  # no schema in front of it, that guard is the only thing standing between a
  # typo and a 403.
  #
  # @param list_id [String] a canonical uuid (see Kiosk::UuidCheck)
  # @param require_owner [Boolean] tighten to role='owner' (invite/remove authority)
  # @return [Boolean]
  def self.reachable?(list_id, require_owner: false)
    scope = of_current_principal.where(list_id: list_id)
    scope = scope.where(role: OWNER) if require_owner
    scope.exists?
  end

  # ── THE PROJECTION BOTH OF tudu's DOORS READ ───────────────────────────────
  # Who else is on one list, in the shape `list_members` publishes — the
  # collaboration surface a member is entitled to see once access is granted.
  #
  # ACCESS IS NOT ASKED HERE for the same reason it is not asked in
  # {Todo.rows_on}: the caller has already been through {ListAccess.check}, and
  # putting the membership predicate in the projection too would leave two copies
  # of one test and invite a future caller to mistake this for the guard. Note
  # that the rows are NOT `of_current_principal` — the point of the verb is the
  # OTHER members — which is exactly why the gate in front of it is the only thing
  # standing between a caller and a foreign list's roster, and why it answers 403
  # rather than 404. See {List.reachable_rows} for why the shape lives on the
  # model at all.
  #
  # What it publishes about a person, and what it MUST NOT. It plucks
  # `display_name`, never `users.email`, and {User.public_name} turns a blank one
  # into an opaque `member-<hex>` derived from the account UUID — never from the
  # address. The rule is not tudu's: spec Section 7.2 forbids a login address in
  # a row about another account at EVERY reach, `consented` included, because
  # consent to share a list is not consent to publish an email address.
  # `demo:redteam`'s NoLoginAddressOnTheRoster beat reads this projection over
  # the wire and fails on an address appearing ANYWHERE in the body, not merely
  # in this field.
  #
  # ── WHAT THE EVENT SURFACE READS, and why neither of these is
  # {.of_current_principal} ──────────────────────────────────────────────────
  #
  # Every membership read above resolves the principal from `CurrentRequest`,
  # which is FIBER-LOCAL. Both callers below run where there is no request to
  # read it from: one inside a socket callback that re-authorises a standing
  # subscription on a timer, the other after a write, deciding who is to be
  # told. So both take what they need as arguments and ask the table.

  # Who is to receive an event about this list — every member, including the
  # one whose action caused it. Deliberately NOT «everyone except the actor»:
  # an assistant learning that its own human ticked something off in the
  # browser is the tudu scenario, not noise.
  #
  # @return [Array<String>] account ids
  def self.account_ids_on(list_id)
    where(list_id: list_id).pluck(:account_id)
  end

  # May this account hold a standing subscription to this list? The
  # request-free twin of {.reachable?}, and the predicate `subject_reachable`
  # calls.
  #
  # @return [Boolean]
  def self.readable_by?(list_id, account_id)
    return false if list_id.to_s.empty? || account_id.to_s.empty?

    where(list_id: list_id, account_id: account_id).exists?
  end

  # @return [Array<Hash>]
  def self.rows_on(list_id)
    where(list_id: list_id).joins(:account)
      .order(role: :desc, created_at: :asc)
      .pluck(:account_id, User.arel_table[:display_name], :role)
      .map { |account_id, display_name, role|
        { "account_id"   => account_id,
          "display_name" => User.public_name(display_name, account_id),
          "role"         => role }
      }
  end
end
