# frozen_string_literal: true

# The ACTING assistant-account's agent row, in the ENGINE's `kiosk.agents`
# table. skooti reads it for exactly one thing: `rent_motorcycle`'s Gate 0 —
# "does the calling agent carry BOTH anonymized boolean KYC attributes".
#
# An engine-owned table with no engine-owned reader, the {Settlement} /
# {CartMandate} shape: kiosk-server writes the row (POST /agents/kyc records
# the attributes an attestation granted), and until K-654 the last reader of it
# was a `conn.execute` string in the initializer. Promoting it into the engine
# is a public-API decision, not a handler conversion.
class Agent < ApplicationRecord
  self.table_name = "kiosk.agents"

  # THE acting agent, and only while it is live. Same shape as
  # {Reservation.owned_by_current_principal} and for the same reason: the
  # identity comes from the transaction GUC, read SQL-side, never from Ruby —
  # so the app-layer assertion and an RLS policy stay the same expression.
  # Frozen literal, no caller value.
  scope :acting, lambda {
    where(arel_table[:id].eq(Arel.sql("kiosk.current_agent_id()"))).where(revoked_at: nil)
  }

  # ONE named anonymized attribute, as `->>` yields it: TEXT, or the string
  # "false" when the key (or the whole column) is absent.
  #
  # THE EXTRACTION STAYS IN SQL, and that is load-bearing rather than
  # stylistic. `kyc_attributes` is jsonb and the engine stores JSON BOOLEANS
  # (`{"age_over_18": true}`), so `->> 'age_over_18'` is the text "true" —
  # and so is a `"true"` STRING, should an issuer ever record one. Reading the
  # column through ActiveRecord instead would hand back a Ruby `true` for the
  # first and a `"true"` for the second, and any Ruby comparison then accepts
  # one spelling and silently refuses the other. Re-implementing `->>` in Ruby
  # to fix that would be hand-rolling a Postgres operator inside a KYC gate,
  # which is the K-724 mistake with a new spelling. So the operator stays
  # Postgres', expressed as Arel (a quoted key, not an interpolated fragment)
  # rather than as a SQL string.
  def self.kyc_attribute(name)
    Arel::Nodes::NamedFunction.new(
      "COALESCE",
      [Arel::Nodes::InfixOperation.new("->>", arel_table[:kyc_attributes], Arel::Nodes.build_quoted(name.to_s)),
       Arel::Nodes.build_quoted("false")],
    )
  end

  # Does the acting agent carry EVERY named attribute as a granted boolean?
  #
  # Only booleans a valid, signed attestation granted were ever persisted — a
  # forged or self-asserted attestation never reaches this column, because the
  # /agents/kyc endpoint rejects a bad signature. So this asks about what the
  # engine recorded, not about what the caller claims.
  #
  # No agent row (revoked, or gone) answers false, exactly as the `.first`-on-
  # an-empty-result the raw SQL relied on did.
  def self.kyc_granted?(*names)
    values = acting.pick(*names.map { |name| kyc_attribute(name) })
    return false if values.nil?

    Array(values).all? { |value| value == "true" }
  end
end
