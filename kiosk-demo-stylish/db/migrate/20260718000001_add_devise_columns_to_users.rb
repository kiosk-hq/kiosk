# frozen_string_literal: true

# Human login columns (Devise database_authenticatable): the account-binding
# walkthrough signs Alice in through the real /users/sign_in form, so users
# gains email + encrypted_password. email stays NULLable — assistant accounts
# registered via kiosk-pop live in this table with no login credentials.
class AddDeviseColumnsToUsers < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    change_table :users, bulk: true do |t|
      t.string :email
      t.string :encrypted_password, null: false, default: ""
    end
    add_index :users, :email, unique: true
  end
end
