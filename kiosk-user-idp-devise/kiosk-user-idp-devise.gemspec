require_relative "lib/kiosk/user_identity_providers/devise/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-user-idp-devise"
  spec.version       = Kiosk::UserIdentityProviders::DeviseVersion::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Devise user-IdP adapter for the Kiosk framework"
  spec.description   = <<~DESC
    kiosk-user-idp-devise is the opt-in user-IdP adapter for Rails
    providers that authenticate principals through Devise. Add it to your
    Gemfile explicitly — the kiosk-all meta-gem pulls in only kiosk-core
    and kiosk-server, so IdP adapters are chosen per provider.

    It reads the signed-in user from the request's Warden proxy
    (`request.env["warden"].user`) passed by kiosk-server and returns a
    {Kiosk::Identity} value object. Covers both Devise paths —
    `database_authenticatable` and `omniauthable` — since both populate the
    Warden user, so the adapter is agnostic to how the user logged in.

    Lockable / confirmable handling comes for free: Devise's
    `active_for_authentication?` already gates the Warden user, so a locked
    or unconfirmed user yields no signed-in user and the request fails as
    unauthenticated with no extra code.

    No hard runtime dependency on Devise itself — the adapter only reads the
    request's Warden user, so the provider's already-installed Devise
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
