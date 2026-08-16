# frozen_string_literal: true

# The join row that grants an account access to a list. This is tudu's
# many-to-many "isolation grows up" surface: every list/todo query & action
# checks a membership EXISTS for the GUC principal, and `remove_member` DELETEs
# one to cut access instantly. `role` is owner|member — the owner (there is at
# least one) holds invite/remove authority.
class Membership < ApplicationRecord
  ROLES = %w[owner member].freeze

  belongs_to :list
  belongs_to :account, class_name: "User", foreign_key: :account_id, inverse_of: :memberships

  validates :role, inclusion: { in: ROLES }
  validates :account_id, uniqueness: { scope: :list_id }

  # THE ACCESS DECISION, and it lives here rather than in a controller because
  # it is a fact about the domain, not about a request: "may the current
  # principal reach this list, and (optionally) does it own it?"
  #
  # tudu is the one demo where BOTH wire halves need this — two queries
  # (list_todos, list_members) and three actions (invite, remove_member,
  # add_todo) — and a controller declares queries OR actions, never both, so it
  # could not live in either one. Putting the PREDICATE on the model and the
  # HTTP refusal in {KioskMembershipGate} splits it along the seam that already
  # exists: this method takes no request, renders nothing and answers true/false,
  # so it can be exercised from a console or a model test with nothing but the
  # GUC set — which is exactly what the concern next door cannot do.
  #
  # The principal is NOT a parameter: it is read inside the SQL from
  # `kiosk.current_user_id()`, the GUC the wire's SessionContext SET LOCALs
  # around the whole request (and the web UI sets identically for the signed-in
  # human). A caller cannot pass a different one, which is the property that
  # makes this un-bypassable — the same reason every query's WHERE reads the GUC
  # instead of an argument.
  #
  # Shape is NOT checked here. `list_id` arrives from the wire and is cast
  # `::uuid` below; a malformed value makes Postgres raise
  # InvalidTextRepresentation. The gate checks the shape FIRST and answers 400
  # (K-581/K-582), so by the time this runs the value is a canonical uuid — and
  # a well-formed but foreign id still answers false, so the shape check never
  # softens the access answer.
  #
  # @param list_id [String] a canonical uuid (see UuidCheck)
  # @param require_owner [Boolean] tighten to role='owner' (invite/remove authority)
  # @return [Boolean]
  def self.reachable?(list_id, require_owner: false)
    conn        = ActiveRecord::Base.connection
    role_clause = require_owner ? "AND role = 'owner'" : ""
    ok = conn.select_value(<<~SQL)
      SELECT EXISTS (
        SELECT 1 FROM memberships
        WHERE list_id = #{conn.quote(list_id.to_s)}::uuid
          AND account_id = kiosk.current_user_id()
          #{role_clause}
      )
    SQL
    ok == true || ok == "t"
  end
end
