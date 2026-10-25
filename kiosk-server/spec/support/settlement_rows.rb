# frozen_string_literal: true

require 'securerandom'

# Writes one settled checkout for a customer, as the pay path records it.
# The including spec defines `conn`, `schema` and `user`, the default account.
module SettlementRows
  # The settlement's PSP reference.
  def settle(cents, at:, account: user, agent: SecureRandom.uuid)
    checkout = insert_checkout(account, agent, cents)
    reference = "pi_#{SecureRandom.hex(4)}"
    conn.execute(<<~SQL.squish)
      INSERT INTO "#{schema}".kiosk_settlements (checkout_mandate_id, user_id, agent_id, issuer, psp_reference, settled_amount_cents, currency, settled_at)
      VALUES ('#{checkout}', '#{account}', '#{agent}', 'i', '#{reference}', #{cents}, 'eur', '#{at.utc.iso8601}')
    SQL
    reference
  end

  def insert_checkout(account, agent, cents)
    reference = SecureRandom.uuid
    conn.select_value(<<~SQL.squish)
      INSERT INTO "#{schema}".kiosk_checkout_mandates (reference, checkout_hash, user_id, agent_id, issuer, line_items, total_amount_cents, currency, expires_at, sd_jwt)
      VALUES ('#{reference}', '#{reference}', '#{account}', '#{agent}', 'i', '[]', #{cents}, 'eur', now(), 'j') RETURNING id
    SQL
  end
end
