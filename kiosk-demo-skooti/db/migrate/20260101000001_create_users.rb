# frozen_string_literal: true

# The provider's users. `id uuid` matches the kiosk:install
# --user-id-type=uuid choice. email and encrypted_password are Devise's login
# columns; email stays NULLable because an assistant account registered over
# the wire has no login.
class CreateUsers < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :users, id: :uuid do |t|
      t.string :email, index: { unique: true }
      t.string :encrypted_password, null: false, default: ""
      t.timestamps
    end
  end
end
