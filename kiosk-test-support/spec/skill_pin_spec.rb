# frozen_string_literal: true

require "digest"

# Skill pin guard (immutable versioned skill files).
#
# Every demo initializer pins `skill_sha256`, the integrity hash a
# hash-verifying agent checks against the published skill file advertised in
# /.well-known/kiosk.json. Published skill versions are immutable
# (skill-vX.Y.Z.md); when a new version ships, every demo must re-pin
# URL + sha together. This spec compares each demo's pin against the SHA-256
# of the pinned version file in the sibling kiosk.tech checkout, so pin
# drift fails the suite immediately.
#
# Umbrella layout only: the parent of reference/ contains kiosk.tech/. On a
# checkout without that sibling (public CI) the whole spec skips —
# public CI must not depend on private/local workspace layout.
RSpec.describe "demo skill_sha256 pins" do
  monorepo_root = File.expand_path("../..", __dir__)  # spec/ -> kiosk-test-support/ -> reference/
  site_root     = File.expand_path("../kiosk.tech", monorepo_root)

  # The well-known default skill URL is defined by kiosk-server; a demo may
  # override it with an explicit `c.skill_url = "…"` in its initializer.
  default_url_source = File.join(
    monorepo_root, "kiosk-server/lib/kiosk/server/configuration_extension.rb"
  )

  initializers = Dir[
    File.join(monorepo_root, "kiosk-demo-*/config/initializers/kiosk.rb")
  ].sort

  before do
    skip "sibling kiosk.tech checkout not present (public CI)" unless File.directory?(site_root)
  end

  it "finds the demo initializers" do
    expect(initializers).not_to be_empty
  end

  initializers.each do |path|
    demo = path[%r{(kiosk-demo-[^/]+)}, 1]

    it "#{demo} pins the sha256 of the published skill version file" do
      src = File.read(path)

      pin = src[/skill_sha256\s*=\s*"([0-9a-f]{64})"/, 1]
      expect(pin).not_to be_nil, "#{demo}: no skill_sha256 pin in #{path}"

      url = src[/skill_url\s*=\s*"([^"]+)"/, 1] ||
            File.read(default_url_source)[/@skill_url\s*\|\|=\s*"([^"]+)"/, 1]
      expect(url).not_to be_nil,
                         "could not determine the skill URL (no skill_url in #{path} " \
                         "and no default in #{default_url_source})"

      skill_file = File.join(site_root, File.basename(url))
      expect(File).to exist(skill_file),
                      "pinned skill file #{File.basename(url)} (from #{url}) " \
                      "not found in #{site_root}"

      actual = Digest::SHA256.hexdigest(File.binread(skill_file))
      expect(pin).to eq(actual),
                     "#{demo} pins skill_sha256 #{pin} but #{File.basename(url)} " \
                     "hashes to #{actual} — re-pin the demos or publish a new " \
                     "immutable skill version"
    end
  end
end
