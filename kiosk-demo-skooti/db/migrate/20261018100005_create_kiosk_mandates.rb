# frozen_string_literal: true

# Migration 005 — kiosk AP2 mandate trail:
# intent_mandates, cart_mandates, payment_mandates, settlements.
# See the Payment (AP2 mandate chain) section of the spec.
class CreateKioskMandates < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".intent_mandates (
        id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        mandate_id        text NOT NULL,
        user_id           uuid NOT NULL,
        agent_id          uuid NOT NULL,
        issuer            text NOT NULL,
        scope             text NOT NULL,
        cap_amount_cents  bigint NOT NULL,
        currency          text NOT NULL,
        expires_at        timestamptz NOT NULL,
        created_at        timestamptz NOT NULL DEFAULT now(),
        raw_jws           text NOT NULL,
        UNIQUE (user_id, mandate_id)
      );
      CREATE INDEX IF NOT EXISTS idx_intent_mandates_user_id  ON "kiosk".intent_mandates (user_id);
      CREATE INDEX IF NOT EXISTS idx_intent_mandates_agent_id ON "kiosk".intent_mandates (agent_id);

      CREATE TABLE IF NOT EXISTS "kiosk".cart_mandates (
        id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        mandate_id         text NOT NULL,
        intent_mandate_id  uuid NOT NULL REFERENCES "kiosk".intent_mandates(id) ON DELETE CASCADE,
        user_id            uuid NOT NULL,
        agent_id           uuid NOT NULL,
        issuer             text NOT NULL,
        line_items         jsonb NOT NULL,
        total_amount_cents bigint NOT NULL,
        currency           text NOT NULL,
        expires_at         timestamptz NOT NULL,
        created_at         timestamptz NOT NULL DEFAULT now(),
        raw_jws            text NOT NULL,
        declined_at        timestamptz,
        UNIQUE (user_id, mandate_id)
      );
      CREATE INDEX IF NOT EXISTS idx_cart_mandates_user_id ON "kiosk".cart_mandates (user_id);
      CREATE INDEX IF NOT EXISTS idx_cart_mandates_intent  ON "kiosk".cart_mandates (intent_mandate_id);

      CREATE TABLE IF NOT EXISTS "kiosk".payment_mandates (
        id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        mandate_id       text NOT NULL,
        cart_mandate_id  uuid NOT NULL REFERENCES "kiosk".cart_mandates(id) ON DELETE CASCADE,
        user_id          uuid NOT NULL,
        agent_id         uuid NOT NULL,
        issuer           text NOT NULL,
        payment_method   text NOT NULL,
        amount_cents     bigint NOT NULL,
        currency         text NOT NULL,
        expires_at       timestamptz,
        created_at       timestamptz NOT NULL DEFAULT now(),
        raw_jws          text NOT NULL,
        UNIQUE (user_id, mandate_id)
      );
      CREATE INDEX IF NOT EXISTS idx_payment_mandates_user_id ON "kiosk".payment_mandates (user_id);
      CREATE INDEX IF NOT EXISTS idx_payment_mandates_cart    ON "kiosk".payment_mandates (cart_mandate_id);

      CREATE TABLE IF NOT EXISTS "kiosk".settlements (
        id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        cart_mandate_id      uuid NOT NULL REFERENCES "kiosk".cart_mandates(id) ON DELETE CASCADE,
        user_id              uuid NOT NULL,
        agent_id             uuid NOT NULL,
        issuer               text NOT NULL,
        psp_reference        text NOT NULL,
        settled_amount_cents bigint NOT NULL,
        currency             text NOT NULL,
        settled_at           timestamptz NOT NULL,
        UNIQUE (cart_mandate_id)
      );
      CREATE INDEX IF NOT EXISTS idx_settlements_user_id ON "kiosk".settlements (user_id);
      CREATE INDEX IF NOT EXISTS idx_settlements_cart    ON "kiosk".settlements (cart_mandate_id);
    SQL
  end

  def down
    # Reverse-FK order: payment_mandates and settlements both reference
    # cart_mandates, so both drop before it; cart_mandates before intent_mandates.
    execute %(DROP TABLE IF EXISTS "kiosk".payment_mandates)
    execute %(DROP TABLE IF EXISTS "kiosk".settlements)
    execute %(DROP TABLE IF EXISTS "kiosk".cart_mandates)
    execute %(DROP TABLE IF EXISTS "kiosk".intent_mandates)
  end
end
