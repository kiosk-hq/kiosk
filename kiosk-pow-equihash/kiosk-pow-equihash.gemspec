# frozen_string_literal: true

require_relative "lib/kiosk/pow/equihash/version"

Gem::Specification.new do |spec|
  spec.name    = "kiosk-pow-equihash"
  spec.version = Kiosk::Pow::Equihash::VERSION
  spec.authors = ["Kiosk"]
  spec.email   = ["hello@fili.pp.ru"]
  spec.summary = "Equihash memory-hard PoW backend for Kiosk (default n=168, k=7; ~17 ms verify, ~1.3 GiB solve)"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  # `lib/**/*` rather than `lib/**/*.rb`: a `*.rb`-shaped glob silently drops the
  # first data file anyone puts under lib/ (a KAT vector, a JSON Schema), which
  # is how kiosk-server lost its app/views. Nothing under lib/ is non-Ruby today,
  # so this changes no byte of the current package — it removes the trap.
  #
  # `bench/` ships because README.md links bench/README.md twice as the evidence
  # for the n=168, k=7 default; without it the shipped README has dead links.
  spec.files = Dir.glob("lib/**/*") + Dir.glob("bench/**/*") +
               %w[solve.py README.md LICENSE.txt] +
               (File.exist?("CHANGELOG.md") ? %w[CHANGELOG.md] : [])

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "base64"
end
