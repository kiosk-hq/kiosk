# frozen_string_literal: true

# Provider's user table — bare-minimum synthetic-user shape.
# `id uuid` to match the kiosk:install --user-id-type=uuid choice; no PII
# fields. Real-world brownfield providers already have this table with
# more columns; here we ship the bare minimum for the e2e.
class CreateUsers < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :users, id: :uuid do |t|
      t.timestamps
    end
  end
end
