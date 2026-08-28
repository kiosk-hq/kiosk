# frozen_string_literal: true

require_relative "lib/kiosk/pow/equihash/version"

Gem::Specification.new do |spec|
  spec.name    = "kiosk-pow-equihash"
  spec.version = Kiosk::Pow::Equihash::VERSION
  spec.authors = ["Phil Pirozhkov"]
  spec.email   = ["hello@fili.pp.ru"]
  spec.summary = "Equihash memory-hard PoW backend for Kiosk (default n=168, k=7; ~17 ms to verify, ~1.3 GiB for the reference solver to solve)"
  spec.description = <<~DESC
    kiosk-pow-equihash is the shipped default proof-of-work backend for the
    Kiosk framework: a pure-Ruby Equihash (Biryukov & Khovratovich birthday-
    collision PoW) VERIFIER with no runtime dependencies — BLAKE2b-256 is
    clean-room pure Ruby from the public-domain BLAKE2 spec, and the gem
    depends on neither kiosk-core nor Rails.

    `Kiosk::Pow::Equihash.verify(salt:, params:, nonce:)` recomputes the 2^k
    BLAKE2b-256 hashes named by the proof's indices, checks that they XOR to
    zero over all n bits, and walks the Wagner collision tree (per-level XOR
    cancellation plus the Zcash-canonical subtree ordering that pins one
    canonical form per solution). Difficulty is set by (n, k) alone — there is
    no post-hoc target check.

    Default parameters are n=168, k=7, chosen by the benchmark in bench/: the
    largest params whose reference solve stays inside a consumer-laptop budget
    (p95 ~10 s on one M-series laptop core, the only hardware the seconds have
    ever been measured on; the ~1.3 GiB peak is THIS solver's table, not the
    host's -- and not a floor (n, k) imposes on every implementation, since a
    memory-optimised solver trades it for time) while verify costs 128 BLAKE2b evaluations —
    ~17 ms and a few KB in pure Ruby. That asymmetry is the point: the gem
    prices a request, it does not equalise hardware. Equihash is neither ASIC-
    nor GPU-proof (it was ASIC'd on Zcash); abuse resistance comes from the
    reputation policy's N-proofs knob and caps, not from this algorithm.

    Ships the provider-side verifier only. A reference Python + numpy solver
    (solve.py) rides along for parity testing and for assistants that need
    one; production solving is the client's concern.
  DESC
  spec.homepage = "https://kiosk.tech"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kiosk-hq/kiosk"
  spec.metadata["changelog_uri"]   = "https://github.com/kiosk-hq/kiosk/blob/main/kiosk-pow-equihash/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/kiosk-hq/kiosk/issues"

  # `lib/**/*` rather than `lib/**/*.rb`: a `*.rb`-shaped glob silently drops the
  # first data file anyone puts under lib/ (a KAT vector, a JSON Schema), which
  # is how kiosk-server lost its app/views. Nothing under lib/ is non-Ruby today,
  # so this changes no byte of the current package — it removes the trap.
  #
  # `bench/` ships because README.md links bench/README.md twice as the evidence
  # for the n=168, k=7 default; without it the shipped README has dead links.
  #
  # Every entry is listed UNGUARDED, CHANGELOG.md included (K-634). The former
  # `File.exist?("CHANGELOG.md") ? … : []` was a fail-open of the same shape
  # removed from kiosk-pow-cuckoo: it was telling the truth only by accident,
  # because the file did not exist. A file this gemspec names and cannot find
  # must break the build, not go quiet.
  spec.files = Dir.glob("lib/**/*") + Dir.glob("bench/**/*") +
               %w[solve.py README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "base64"
end
