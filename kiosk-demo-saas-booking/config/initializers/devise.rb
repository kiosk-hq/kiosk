# frozen_string_literal: true

# Minimal Devise setup — database_authenticatable only. The demo's human
# account holders (Alice, Bob) sign in with email + password at
# /users/sign_in; the Kiosk account-binding surfaces (device verify page,
# link mint, unlink) then authenticate that Warden session through the
# kiosk-user-idp-devise adapter (see config/initializers/kiosk.rb).
# Assistants never use this channel — they authenticate with kiosk-pop
# key possession.
Devise.setup do |_config|
  require "devise/orm/active_record"
end
