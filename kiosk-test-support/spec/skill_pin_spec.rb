# frozen_string_literal: true

require 'digest'

# Skill pin check (immutable versioned skill files).
#
# Nine consumers name a skill. Seven demo initializers pin `skill_url` and
# `skill_sha256`; kiosk-server ships the default `skill_url` that every other
# operator inherits by not setting one; and kiosk-server's well_known_spec
# asserts what the discovery document advertises. The engine default is a
# consumer in its own right here, not a fallback.
#
# This spec owns what needs the published BYTES:
#   * INTEGRITY: each pinned `skill_sha256` equals the SHA-256 of the pinned
#     file as kiosk.tech publishes it. A hash-verifying AI assistant refuses the
#     skill on a mismatch, so a stale pin stops the operator being usable.
#   * PATCH AGREEMENT: the engine default and the demos name the SAME cut.
# It does not check that the pinned version matches
# `Kiosk::Protocol::API_VERSION`: it reads bytes, not version strings.
#
# The byte groups need the published cuts from the kiosk.tech repository, so
# they run when that repository sits beside this one and skip when it does not.
# `ci.yml`'s `published-bytes` job checks it out beside this repository and
# sets `KIOSK_REQUIRE_SITE_SIBLING=1`: then an absent sibling is a failure that
# names the path, never a skip.
module SkillPin
  MONOREPO_ROOT = File.expand_path('../..', __dir__)
  SITE_ROOT     = File.expand_path('../kiosk.tech', MONOREPO_ROOT)
  DEFAULT_URL_SOURCE = File.join(MONOREPO_ROOT, 'kiosk-server/lib/kiosk/server/configuration_extension.rb')
  GRANT_SOURCE = File.join(MONOREPO_ROOT, 'kiosk-server/lib/kiosk/server/device_code_grant.rb')
  INITIALIZERS = Dir[File.join(MONOREPO_ROOT, 'kiosk-demo-*/config/initializers/kiosk.rb')].freeze

  module_function

  # The default skill URL kiosk-server ships, or nil when it cannot be read.
  def default_url
    return nil unless File.exist?(DEFAULT_URL_SOURCE)

    File.read(DEFAULT_URL_SOURCE)[/@skill_url\s*\|\|=\s*['"]([^'"]+)['"]/, 1]
  end

  # demo => {url:, sha:, path:}. A demo that sets no `skill_url` inherits
  # kiosk-server's default, which is a legitimate configuration.
  def pins
    INITIALIZERS.to_h do |path|
      src = File.read(path)
      [path[%r{(kiosk-demo-[^/]+)}, 1],
       { url: src[/skill_url\s*=\s*['"]([^'"]+)['"]/, 1] || default_url,
         sha: src[/skill_sha256\s*=\s*['"]([0-9a-f]{64})['"]/, 1],
         path: path }]
    end
  end

  def published_sha(url) = Digest::SHA256.hexdigest(File.binread(published_file(url)))

  def published_file(url) = File.join(SITE_ROOT, File.basename(url))

  # True when the sibling checkout is present. An environment that promised it
  # gets a failure instead of a skip: a skipped example reads as a passing one
  # in every CI summary line.
  def site_present?
    return true if File.directory?(SITE_ROOT)
    return false unless ENV['KIOSK_REQUIRE_SITE_SIBLING'] == '1'

    raise 'KIOSK_REQUIRE_SITE_SIBLING=1 was set, so the caller undertook to put the ' \
          "published kiosk.tech checkout at #{SITE_ROOT} — and it is not there. Do NOT " \
          "relax this to a skip: these examples are the only thing that compares a demo's " \
          '`skill_sha256` against the bytes an AI assistant will actually fetch, and a ' \
          'skipped example reads as a passing one in every summary line CI prints.'
  end

  # The OAuth errors `DeviceCodeGrant` can emit during a ceremony, read from
  # its `failure(:code, …)` calls and `[:code, …]` table rows. invalid_request
  # is a malformed call (no device_code), not an outcome of a ceremony.
  def emitted_grant_errors
    File.read(GRANT_SOURCE).scan(/(?:failure\(|\[):([a-z_]+)/).flatten.uniq - %w[invalid_request]
  end

  # The claim ceremony's bullet and its sub-bullets in the skill at `url`, up
  # to the sibling bullet.
  def ceremony_section(url)
    File.read(published_file(url))[/^- \*\*No code from the human\*\*.*?(?=^- \*\*The human hands you a code)/m]
  end
end

RSpec.shared_context 'with the published kiosk.tech checkout' do
  before { skip 'sibling kiosk.tech checkout not present (public CI)' unless SkillPin.site_present? }
end

RSpec.describe 'the skill pin' do
  it 'finds the demo initializers' do
    expect(SkillPin::INITIALIZERS).not_to be_empty
  end

  it "reads kiosk-server's default skill_url" do
    expect(SkillPin.default_url).not_to be_nil,
                                        "no `@skill_url ||= \"…\"` default found in #{SkillPin::DEFAULT_URL_SOURCE}. " \
                                        'That default is what every operator who does not set `skill_url` ' \
                                        'advertises in /.well-known/kiosk.json, so this guard must not ' \
                                        'carry on without it — teach it where the default moved.'
  end

  # Runs without the sibling checkout. The message names no version: it prints
  # every URL and derives the series from them.
  it "is the same published cut in kiosk-server's default and in every demo" do
    skip "kiosk-server's default is unreadable (asserted above)" if SkillPin.default_url.nil?

    named  = SkillPin.pins.transform_values { it[:url] }.merge('kiosk-server (default)' => SkillPin.default_url)
    series = named.values.filter_map { it[/skill-v(\d+\.\d+)\./, 1] }.uniq.sort
    expect(named.values.uniq.size).to eq(1),
                                      "the skill_url consumers disagree on which cut is current:\n" \
                                      "#{named.map { |who, url| "  #{who}: #{url}" }.join("\n")}\n" \
                                      'All nine consumers re-pin together when a new skill is cut ' \
                                      "(ADR-0012). Series named: #{series.join(' / ')}."
  end
end

# The engine default carries no sha256 of its own, so the property is that the
# file it names is published and is the one the demos verify against.
RSpec.describe "the skill pin: kiosk-server's default against the published bytes" do
  include_context 'with the published kiosk.tech checkout'

  it "kiosk-server's default names a published file, the same one the demos pin" do
    url = SkillPin.default_url
    skip "kiosk-server's default is unreadable (asserted above)" if url.nil?
    expect(File).to exist(SkillPin.published_file(url)),
                    "kiosk-server defaults skill_url to #{url}, but #{File.basename(url)} is not published in " \
                    "#{SkillPin::SITE_ROOT} — every operator who does not override it advertises a URL that 404s, " \
                    'and an AI assistant that cannot fetch the pinned skill cannot verify it.'

    actual    = SkillPin.published_sha(url)
    demo_shas = SkillPin.pins.values.filter_map { it[:sha] }.uniq
    expect(demo_shas).to eq([actual]),
                         "the default cut #{File.basename(url)} hashes to #{actual}, " \
                         "but the demos pin #{demo_shas.inspect} — the default and the demo pins " \
                         'are supposed to be the same artefact. Re-pin them together, or publish ' \
                         'a new immutable cut and move all nine consumers to it.'
  end
end

RSpec.describe "the skill pin: each demo's sha256 against the published bytes" do
  include_context 'with the published kiosk.tech checkout'

  SkillPin.pins.each do |demo, pin|
    it "#{demo} pins the sha256 of the published skill version file" do
      expect(pin[:sha]).not_to be_nil, "#{demo}: no skill_sha256 pin in #{pin[:path]}"
      expect(pin[:url]).not_to be_nil,
                               "could not determine the skill URL (no skill_url in #{pin[:path]} " \
                               "and no default in #{SkillPin::DEFAULT_URL_SOURCE})"
      expect(File).to exist(SkillPin.published_file(pin[:url])),
                      "pinned skill file #{File.basename(pin[:url])} (from #{pin[:url]}) not found in #{SkillPin::SITE_ROOT}"

      actual = SkillPin.published_sha(pin[:url])
      expect(pin[:sha]).to eq(actual),
                           "#{demo} pins skill_sha256 #{pin[:sha]} but #{File.basename(pin[:url])} " \
                           "hashes to #{actual} — re-pin the demos or publish a new immutable skill version"
    end
  end
end

# The pinned cut must teach an assistant to END its device-code poll: a
# ceremony the human denied, or one whose `expires_in` elapsed, must not poll
# forever. The vocabulary is derived from the engine, so a code added there and
# not taught to the skill fails here.
RSpec.describe 'the skill pin: the device-code poll in the pinned cut' do
  include_context 'with the published kiosk.tech checkout'

  it 'the pinned cut names every device-grant error the engine can emit, and a give-up horizon' do
    expect(File).to exist(SkillPin::GRANT_SOURCE)
    emitted = SkillPin.emitted_grant_errors
    expect(emitted.size).to be >= 5,
                            "parsed only #{emitted.size} failure code(s) out of " \
                            "#{SkillPin::GRANT_SOURCE}; the call shape changed and this expectation is blind"

    name    = File.basename(SkillPin.pins.values.filter_map { it[:url] }.uniq.first)
    section = SkillPin.ceremony_section(name)
    expect(section).not_to be_nil, "could not locate the claim-ceremony bullet in #{name}"

    missing = emitted.reject { |code| section.include?(code) }
    expect(missing).to be_empty,
                       "#{name} teaches the device-code poll without naming #{missing.join(', ')} — the engine " \
                       "emits #{emitted.sort.join(', ')} (#{SkillPin::GRANT_SOURCE}), and an error the skill " \
                       'does not name is an error the assistant loops on'
    expect(section).to match(/GIVE UP/),
                       "#{name}'s device-code poll states no give-up horizon. Nothing pushes on approval, so a " \
                       "loop without one runs until the assistant's budget dies — the card-setup and KYC polls " \
                       'both say where to stop, and this is the third such poll.'
    expect(section).to match(/TERMINAL/),
                       "#{name}'s device-code poll marks no outcome TERMINAL, so a denied or expired ceremony has no stated stop condition."
  end
end
