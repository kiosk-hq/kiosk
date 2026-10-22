# frozen_string_literal: true

# The accounts that registration opened for assistants, and the account that
# each one merged into at its first binding. The spend of an account counts the
# settlements and visits of the assistant accounts merged into it.
#
# An account with no email is an assistant account. An assistant account whose
# assistant paid on it and now sits on another account merged into that account.
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
      INSERT INTO "kiosk".assistant_accounts (user_id) SELECT id FROM "users" WHERE email IS NULL;
      UPDATE "kiosk".assistant_accounts aa SET merged_into = a.user_id, merged_at = now()
        FROM "kiosk".settlements s JOIN "kiosk".agents a ON a.id = s.agent_id
        WHERE s.user_id = aa.user_id AND a.user_id <> aa.user_id;
    SQL
  end

  def down
    execute 'DROP TABLE "kiosk".assistant_accounts'
  end
end
