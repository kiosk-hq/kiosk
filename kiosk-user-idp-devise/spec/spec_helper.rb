# frozen_string_literal: true

require "kiosk/user_identity_providers/devise"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.warnings = false

  # Reset Kiosk.configuration between examples to keep tests independent.
  config.before(:each) { Kiosk.reset! }
end

# Test doubles — kiosk-user-idp-devise does NOT depend on Devise at runtime
# or at test time; it only reads `request.current_user`. A small Ruby
# struct-like double covers both shapes.

class FakeUser
  attr_reader :id

  def initialize(id:, kiosk_role: :__unset__)
    @id         = id
    @kiosk_role = kiosk_role
  end

  # Only define `#kiosk_role` if the test set one — mimics provider opt-in.
  def kiosk_role
    @kiosk_role
  end

  # Hide `#kiosk_role` from `respond_to?` unless the test opted in.
  def respond_to?(name, include_private = false)
    return false if name == :kiosk_role && @kiosk_role == :__unset__

    super
  end
end

class FakeRequest
  attr_reader :current_user

  def initialize(current_user: nil)
    @current_user = current_user
  end
end

# Minimal Warden::Proxy stand-in: `#user` returns the signed-in principal
# (nil when not signed in). Real Warden takes an optional scope; the adapter
# calls it scopeless, matching Devise's single-model default scope.
class FakeWarden
  def initialize(user: nil)
    @user = user
  end

  def user(_scope = nil)
    @user
  end
end

# The shipped-wire shape: an `ActionDispatch::Request`-like object. It does
# NOT expose `#current_user` (that is a controller helper, not a request
# method) — the adapter must read the Warden user from `#env`.
class FakeActionDispatchRequest
  attr_reader :env

  def initialize(warden: nil)
    @env = warden.nil? ? {} : { "warden" => warden }
  end
end
