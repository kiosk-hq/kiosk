# frozen_string_literal: true

# AP2 v0.2 has two mandates, Checkout and Payment, and no Intent. The cart
# mandate becomes the checkout mandate, and every row keeps its settlement and
# refunds. A row signed before this migration has no checkout hash, so it takes
# its own reference, which is unique.
class ReshapeKioskMandatesForAp2V02 < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      ALTER TABLE "kiosk".cart_mandates DROP COLUMN intent_mandate_id;
      DROP TABLE "kiosk".intent_mandates;

      ALTER TABLE "kiosk".cart_mandates RENAME TO checkout_mandates;
      ALTER TABLE "kiosk".checkout_mandates RENAME CONSTRAINT cart_mandates_pkey TO checkout_mandates_pkey;
      ALTER TABLE "kiosk".checkout_mandates RENAME COLUMN mandate_id TO reference;
      ALTER TABLE "kiosk".checkout_mandates
        RENAME CONSTRAINT cart_mandates_user_id_mandate_id_key TO checkout_mandates_user_id_reference_key;
      ALTER TABLE "kiosk".checkout_mandates RENAME COLUMN raw_jws TO sd_jwt;
      ALTER TABLE "kiosk".checkout_mandates ADD COLUMN checkout_hash text;
      UPDATE "kiosk".checkout_mandates SET checkout_hash = reference;
      ALTER TABLE "kiosk".checkout_mandates ALTER COLUMN checkout_hash SET NOT NULL;
      ALTER INDEX "kiosk".idx_cart_mandates_user_id RENAME TO idx_checkout_mandates_user_id;
      CREATE UNIQUE INDEX idx_checkout_mandates_live_checkout
        ON "kiosk".checkout_mandates (user_id, checkout_hash) WHERE declined_at IS NULL;

      ALTER TABLE "kiosk".payment_mandates RENAME COLUMN mandate_id TO reference;
      ALTER TABLE "kiosk".payment_mandates
        RENAME CONSTRAINT payment_mandates_user_id_mandate_id_key TO payment_mandates_user_id_reference_key;
      ALTER TABLE "kiosk".payment_mandates RENAME COLUMN cart_mandate_id TO checkout_mandate_id;
      ALTER TABLE "kiosk".payment_mandates
        RENAME CONSTRAINT payment_mandates_cart_mandate_id_fkey TO payment_mandates_checkout_mandate_id_fkey;
      ALTER TABLE "kiosk".payment_mandates RENAME COLUMN payment_method TO payment_instrument;
      ALTER TABLE "kiosk".payment_mandates RENAME COLUMN raw_jws TO sd_jwt;
      ALTER INDEX "kiosk".idx_payment_mandates_cart RENAME TO idx_payment_mandates_checkout;

      ALTER TABLE "kiosk".settlements RENAME COLUMN cart_mandate_id TO checkout_mandate_id;
      ALTER TABLE "kiosk".settlements
        RENAME CONSTRAINT settlements_cart_mandate_id_fkey TO settlements_checkout_mandate_id_fkey;
      ALTER TABLE "kiosk".settlements
        RENAME CONSTRAINT settlements_cart_mandate_id_key TO settlements_checkout_mandate_id_key;
      ALTER INDEX "kiosk".idx_settlements_cart RENAME TO idx_settlements_checkout;
    SQL
  end

  # The intent mandates are dropped, so the old trail cannot come back.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
