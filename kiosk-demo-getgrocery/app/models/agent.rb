# frozen_string_literal: true

# The ACTING assistant-account's agent row, in the ENGINE's `kiosk.agents`
# table. getgrocery reads it for exactly one thing: `create_order`'s age gate —
# "does the calling agent carry the anonymized boolean age_over_18".
#
# An engine-owned table with no engine-owned reader, the {Settlement} /
# {CartMandate} shape: kiosk-server writes the row (POST /agents/kyc records the
# attributes a verified attestation granted), and until K-654 the last reader of
# it was a `conn.execute` heredoc in the initializer. Promoting it into the
# engine is a public-API decision, not a handler conversion.
class Agent < ApplicationRecord
  self.table_name = "kiosk.agents"

  # The named anonymized attributes a valid attestation granted this agent —
  # ROWS since K-656, one per granted name, in the engine's own
  # `kiosk.kyc_attributes` table.
  has_many :kyc_attributes, class_name: "KycAttribute", inverse_of: :agent,
                            foreign_key: :agent_id, dependent: nil

  # THE acting agent, and only while it is live. Same shape as
  # {Order.owned_by_current_principal} and for the same reason: the identity
  # comes from the transaction GUC, read SQL-side, never from Ruby — so the
  # app-layer assertion and an RLS policy stay the same expression. Frozen
  # literal, no caller value.
  scope :acting, lambda {
    where(arel_table[:id].eq(Arel.sql("kiosk.current_agent_id()"))).where(revoked_at: nil)
  }

  # Does the acting agent carry EVERY named attribute as a granted boolean?
  #
  # THE QUESTION IS AN EXISTENCE TEST, AND THAT IS WHAT MAKES IT SAFE. Until
  # K-656 the grants were a jsonb map on this row and this method had to
  # extract a VALUE — `COALESCE(kyc_attributes ->> 'age_over_18', 'false')`,
  # deliberately in Postgres, because the engine stored JSON booleans and a
  # Ruby comparison would accept one spelling of true and silently refuse the
  # other inside the gate that decides whether alcohol is sold. There is no
  # value any more: the grant IS the row, so this counts the required names
  # that are present and compares the count. Nothing here can answer NULL, and
  # no spelling of `true` reaches this side at all — the engine judges that
  # once, on the write, in Postgres (`jsonb_each(...) WHERE value =
  # 'true'::jsonb`).
  #
  # Only names a valid, signed attestation granted were ever written — a forged
  # or self-asserted attestation never reaches the table, because the
  # /agents/kyc endpoint rejects a bad signature. So this asks about what the
  # engine recorded, not about what the caller claims.
  #
  # No agent row (revoked, or gone) answers false: `acting` is the subquery the
  # rows are matched against, so it yields nothing and the count is 0. Asking
  # for no attributes at all answers false too — a gate that required nothing
  # would be a gate that passed everyone.
  def self.kyc_granted?(*names)
    required = names.map(&:to_s).uniq
    return false if required.empty?

    KycAttribute.where(agent_id: acting.select(:id), name: required)
                .distinct.count(:name) == required.size
  end
end
