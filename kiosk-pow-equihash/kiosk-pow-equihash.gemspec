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

  spec.files = Dir.glob("lib/**/*.rb") + %w[solve.py LICENSE.txt]

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "base64"
end
