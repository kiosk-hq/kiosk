require_relative "lib/kiosk/user_identity_providers/devise/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-user-idp-devise"
  spec.version       = Kiosk::UserIdentityProviders::DeviseVersion::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["phil@kiosk.tech"]

  spec.summary       = "Devise user-IdP adapter for the Kiosk framework"
  spec.description   = <<~DESC
    kiosk-user-idp-devise is the bundled-by-default user-IdP adapter for
    Rails providers that authenticate principals through Devise.

    It reads `current_user` from the controller passed by kiosk-server and
    returns a {Kiosk::Identity} value object. Covers both Devise paths —
    `database_authenticatable` and `omniauthable` — since both populate
    `current_user`, so the adapter is agnostic to how the user logged in.

    Lockable / confirmable handling comes for free: Devise's
    `active_for_authentication?` already gates `current_user`, so a locked
    or unconfirmed user yields `current_user == nil` and the request fails
    as unauthenticated with no extra code.

    No hard runtime dependency on Devise itself — the adapter only calls
    `request.current_user`, so the provider's already-installed Devise
    satisfies the requirement.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]     = spec.homepage
  spec.metadata["source_code_uri"]  = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]    = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-user-idp-devise/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "kiosk-core", "~> 0.0"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.2"
end
