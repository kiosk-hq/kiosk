# frozen_string_literal: true

require 'digest'
require 'yaml'
require 'kiosk/server/well_known'
require 'kiosk/server/oauth_error'

# Skill pin check (immutable versioned skill files).
#
# kiosk-server ships the default `skill_url`, and no demo sets its own. Each of
# the seven demos sets `skill_sha256` in its initializer and names the skill
# version that digest is for in its skill pin test (`hashed_version:`).
#
# This spec owns what needs the published BYTES:
#   * INTEGRITY: each pinned `skill_sha256` equals the SHA-256 of the default
#     file as kiosk.tech publishes it. A hash-verifying AI assistant refuses the
#     skill on a mismatch, so a stale pin stops the operator being usable.
#   * PATCH AGREEMENT: the engine default and every demo's `hashed_version:`
#     name the SAME cut.
# It does not check that the pinned version matches
# `Kiosk::Protocol::API_VERSION`: bin/check-version-parity does.
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

  # demo => {url:, sha:, hashed_version:, path:}. The url is kiosk-server's
  # default; `own_url` is a `skill_url` the initializer sets, which it must not.
  def pins
    INITIALIZERS.to_h do |path|
      src = File.read(path)
      [path[%r{(kiosk-demo-[^/]+)}, 1],
       { url: default_url,
         own_url: src[/skill_url\s*=\s*['"]([^'"]+)['"]/, 1],
         sha: src[/skill_sha256\s*=\s*['"]([0-9a-f]{64})['"]/, 1],
         hashed_version: hashed_version(File.expand_path('../../..', path)),
         path: path }]
    end
  end

  # The version a demo's skill pin test names; nil when it has no such test.
  def hashed_version(demo_dir)
    test = Dir[File.join(demo_dir, '{test,spec}/kiosk_skill_pin_{test,spec}.rb')].first
    test && File.read(test)[/hashed_version: '(\d+\.\d+\.\d+)'/, 1]
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

  # The OAuth errors that the token and device-authorization endpoints can
  # answer: the engine's closed list without `invalid_client_metadata`, which
  # only registration answers.
  def token_errors = Kiosk::Server::OauthError::CODES - %w[invalid_client_metadata]

  # The OAuth errors `DeviceCodeGrant` emits during a ceremony, read from its
  # `fail!(:code, …)` calls and `[:code, …]` table rows.
  def emitted_grant_errors
    File.read(GRANT_SOURCE).scan(/(?:fail!\(|\[):([a-z_]+)/).flatten.uniq
  end

  # The binding section of the skill at `url`: the two ceremonies and the
  # error list of their `/oauth/*` requests, up to the give-up horizon.
  def ceremony_section(url)
    File.read(published_file(url))[/^- \*\*No code from the human\*\*.*?^- \*\*GIVE UP[^\n]*/m]
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

  it 'finds no demo that sets its own skill_url' do
    own = SkillPin.pins.select { |_, pin| pin[:own_url] }.keys
    expect(own).to be_empty, "#{own.join(', ')} set skill_url; kiosk-server gives it, so remove the line"
  end

  # Runs without the sibling checkout. The message names no version: it prints
  # every version and derives the series from them.
  it "is the same published cut in kiosk-server's default and in every demo" do
    skip "kiosk-server's default is unreadable (asserted above)" if SkillPin.default_url.nil?

    named  = SkillPin.pins.transform_values { it[:hashed_version] }
                     .merge('kiosk-server (default)' => SkillPin.default_url[/skill-v(\d+\.\d+\.\d+)\.md/, 1])
    series = named.values.compact.map { it[/\A\d+\.\d+/] }.uniq.sort
    expect(named.values.uniq.size).to eq(1),
                                      "kiosk-server's default and the demos' skill pin tests (hashed_version:) " \
                                      "disagree on which cut is current:\n" \
                                      "#{named.map { |who, version| "  #{who}: #{version.inspect}" }.join("\n")}\n" \
                                      'All consumers re-pin together when a new skill is cut. ' \
                                      "Series named: #{series.join(' / ')}."
  end

  # The engine default carries no sha256 of its own, so the property is that the
  # file it names is published and is the one the demos verify against.
  describe "the skill pin: kiosk-server's default against the published bytes" do
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
                           'a new immutable cut and move every consumer to it.'
    end
  end

  describe "the skill pin: each demo's sha256 against the published bytes" do
    include_context 'with the published kiosk.tech checkout'

    SkillPin.pins.each do |demo, pin|
      it "#{demo} pins the sha256 of the published skill version file" do
        expect(pin[:sha]).not_to be_nil, "#{demo}: no skill_sha256 pin in #{pin[:path]}"
        expect(pin[:url]).not_to be_nil, "no default skill_url in #{SkillPin::DEFAULT_URL_SOURCE}"
        expect(File).to exist(SkillPin.published_file(pin[:url])),
                        "pinned skill file #{File.basename(pin[:url])} (from #{pin[:url]}) not found in #{SkillPin::SITE_ROOT}"

        actual = SkillPin.published_sha(pin[:url])
        expect(pin[:sha]).to eq(actual),
                             "#{demo} pins skill_sha256 #{pin[:sha]} but #{File.basename(pin[:url])} " \
                             "hashes to #{actual} — re-pin the demos or publish a new immutable skill version"
      end
    end
  end

  # The skills index and agents.json repeat the pinned cut's `name` and
  # `description`; Agent Skills Discovery asks that they match the file.
  describe 'the skill pin: the name and description the engine repeats' do
    include_context 'with the published kiosk.tech checkout'

    it "match the pinned cut's frontmatter" do
      name = File.basename(SkillPin.default_url)
      head = YAML.safe_load(File.read(SkillPin.published_file(name))[/\A---\n(.*?)\n---\n/m, 1])
      expect(head.values_at('name', 'description'))
        .to eq([Kiosk::Server::WellKnown::SKILL_NAME, Kiosk::Server::WellKnown::SKILL_DESCRIPTION]),
            "#{name}'s frontmatter names #{head['name'].inspect}; copy its name and description into " \
            'Kiosk::Server::WellKnown::SKILL_NAME and SKILL_DESCRIPTION'
    end
  end

  # The pinned cut must teach every error the token endpoint answers, and must
  # teach an assistant to END its device-code poll: a ceremony the human
  # denied, or one whose `expires_in` elapsed, must not poll forever. The
  # vocabulary is derived from the engine, so a code added there and not taught
  # to the skill fails here.
  describe 'the skill pin: the device-code poll in the pinned cut' do
    include_context 'with the published kiosk.tech checkout'

    it 'the pinned cut names every token-endpoint error the engine can answer, and a give-up horizon' do
      expect(File).to exist(SkillPin::GRANT_SOURCE)
      emitted = SkillPin.token_errors
      expect(emitted.size).to eq(9), "the engine lists #{emitted.size} token-endpoint errors, not nine: #{emitted.join(', ')}"
      grant = SkillPin.emitted_grant_errors
      expect(grant.size).to be >= 5,
                            "parsed only #{grant.size} failure code(s) out of " \
                            "#{SkillPin::GRANT_SOURCE}; the call shape changed and this expectation is blind"
      expect(grant - emitted).to be_empty, "#{SkillPin::GRANT_SOURCE} emits #{(grant - emitted).join(', ')}, outside the engine's list"

      name    = File.basename(SkillPin.pins.values.filter_map { it[:url] }.uniq.first)
      section = SkillPin.ceremony_section(name)
      expect(section).not_to be_nil, "could not locate the claim-ceremony bullet in #{name}"

      missing = emitted.reject { |code| section.include?(code) }
      expect(missing).to be_empty,
                         "#{name} teaches the binding requests without naming #{missing.join(', ')} — the engine " \
                         "answers #{emitted.sort.join(', ')}, and an error the skill " \
                         'does not name is an error the assistant loops on'
      expect(section).to include('GIVE UP'),
                         "#{name}'s device-code poll states no give-up horizon. Nothing pushes on approval, so a " \
                         "loop without one runs until the assistant's budget dies — the card-setup and KYC polls " \
                         'both say where to stop, and this is the third such poll.'
      expect(section).to include('TERMINAL'),
                         "#{name}'s device-code poll marks no outcome TERMINAL, so a denied or expired ceremony has no stated stop condition."
    end
  end
end
