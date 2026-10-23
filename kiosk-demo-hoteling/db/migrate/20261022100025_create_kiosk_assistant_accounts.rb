# frozen_string_literal: true

# The accounts that registration opened for assistants, and the account that
# each one merged into at its first binding. Registration writes each row; the
# table starts empty.
class CreateKioskAssistantAccounts < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~SQL
      CREATE TABLE "kiosk".assistant_accounts (
        user_id      uuid PRIMARY KEY REFERENCES "users"(id) ON DELETE CASCADE,
        merged_into  uuid REFERENCES "users"(id) ON DELETE CASCADE,
        merged_at    timestamptz
      );
      CREATE INDEX idx_assistant_accounts_merged_into
        ON "kiosk".assistant_accounts (merged_into) WHERE merged_into IS NOT NULL;
    SQL
  end

  def down
    execute 'DROP TABLE "kiosk".assistant_accounts'
  end
end
