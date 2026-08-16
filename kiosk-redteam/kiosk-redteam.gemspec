require_relative "lib/kiosk/redteam/version"

Gem::Specification.new do |spec|
  spec.name          = "kiosk-redteam"
  spec.version       = Kiosk::Redteam::VERSION
  spec.authors       = ["Phil Pirozhkov"]
  spec.email         = ["hello@fili.pp.ru"]

  spec.summary       = "Adversarial regression harness for Kiosk providers"
  spec.description   = <<~DESC
    kiosk-redteam drives hostile HTTP scenarios against any Kiosk provider
    and asserts each attack is correctly blocked (HTTP 401/402/403 or a domain
    denial response).  A scenario that finds a real breach fails loudly.

    Ships: an HTTP Client (register + Equihash PoW, kyc, query/run/pay with
    RS256 mandate signing), a Scenario/Verdict/Runner framework, and a library
    of generic attack scenarios parameterised by a per-provider Profile.
    Intended to back a `demo:redteam` rake task in each demo gem.

    No dependency on kiosk-core or Rails.
  DESC
  spec.homepage      = "https://kiosk.tech"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]   = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-redteam/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/kiosk-hq/kiosk/issues"

  spec.files         = Dir.glob("lib/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  # The Equihash reference solver (solve.py) the client shells out to on a
  # 402 registration challenge ships inside kiosk-pow-equihash; the client
  # locates it via that gem's public Kiosk::Pow::Equihash.solver_path.
  spec.add_dependency "kiosk-pow-equihash", "~> 0.3.0"
  # RS256 mandate signing / verification in specs
  spec.add_dependency "jwt", ">= 2.0", "< 4.0"
  # base64 was a default gem through Ruby 3.3 but became a BUNDLED gem in 3.4,
  # so it has to be declared. Required at load time by scenario.rb and
  # scenarios/privilege_self_selection.rb; until now it arrived only by
  # accident, as a transitive dependency of jwt.
  spec.add_dependency "base64"

  spec.add_development_dependency "rspec",   "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.0"
  spec.add_development_dependency "rake",    "~> 13.2"
end
