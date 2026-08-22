# frozen_string_literal: true

require "digest"

# Skill pin guard (immutable versioned skill files).
#
# NINE CONSUMERS NAME A SKILL, AND ALL NINE ARE COVERED HERE OR NEXT DOOR.
# Seven demo initializers pin `skill_url` + `skill_sha256`; kiosk-server ships
# the default `skill_url` every OTHER operator inherits by not setting one; and
# kiosk-server's own well_known_spec asserts what the discovery document
# advertises. Until K-750 the middle one was covered by nothing: this spec read
# the engine default only as the right-hand side of a `||`, and since all seven
# demos set `skill_url` explicitly that branch never evaluated. The engine
# default — the value a third-party operator actually ships — was asserted
# solely by a hand-maintained literal in well_known_spec, which now derives it
# instead. It is a first-class case here, not a fallback.
#
# WHAT THIS SPEC OWNS, AND WHAT IT DELIBERATELY DOES NOT.
#
#   HERE, because it needs the published BYTES:
#     * INTEGRITY — each pinned `skill_sha256` equals the SHA-256 of the
#       pinned file as kiosk.tech actually publishes it. A hash-verifying AI
#       assistant refuses the skill on a mismatch, so a stale pin does not
#       degrade, it stops the operator being transactable.
#     * PATCH AGREEMENT — the engine default and the demos name the SAME cut.
#
#   NOT HERE — bin/check-version-parity owns it (rule C): that every pinned
#   `skill_url`, the engine default included, shares MAJOR.MINOR with
#   `Kiosk::Protocol::API_VERSION`. That check needs no sibling checkout and no
#   network, so unlike this spec it runs in public CI. Do not restate it here.
#   The division is by what each can honestly see: it reads version STRINGS
#   against the protocol, this reads published BYTES.
#
# Umbrella layout only: the parent of reference/ contains kiosk.tech/. On a
# checkout without that sibling (public CI) the byte-level group skips —
# public CI must not depend on private/local workspace layout. The string-level
# group below has no such dependency and always runs.
RSpec.describe "the skill pin" do
  monorepo_root = File.expand_path("../..", __dir__)  # spec/ -> kiosk-test-support/ -> reference/
  site_root     = File.expand_path("../kiosk.tech", monorepo_root)

  # The default skill URL kiosk-server ships. Read unconditionally, at load
  # time, because it is a consumer in its own right — not a fallback consulted
  # when a demo omits its own.
  default_url_source = File.join(
    monorepo_root, "kiosk-server/lib/kiosk/server/configuration_extension.rb"
  )
  default_url =
    File.exist?(default_url_source) &&
    File.read(default_url_source)[/@skill_url\s*\|\|=\s*"([^"]+)"/, 1]
  default_url = nil unless default_url.is_a?(String)

  initializers = Dir[
    File.join(monorepo_root, "kiosk-demo-*/config/initializers/kiosk.rb")
  ].sort

  # A demo that sets no `skill_url` inherits kiosk-server's default — a
  # legitimate configuration, and the reason `default_url` is a real value
  # here rather than a `||` tail nothing evaluates.
  pins = initializers.to_h do |path|
    src = File.read(path)
    [
      path[%r{(kiosk-demo-[^/]+)}, 1],
      { url: src[/skill_url\s*=\s*"([^"]+)"/, 1] || default_url,
        sha: src[/skill_sha256\s*=\s*"([0-9a-f]{64})"/, 1],
        path: path }
    ]
  end

  it "finds the demo initializers" do
    expect(initializers).not_to be_empty
  end

  it "reads kiosk-server's default skill_url" do
    expect(default_url).not_to be_nil,
                               "no `@skill_url ||= \"…\"` default found in #{default_url_source}. " \
                               "That default is what every operator who does not set `skill_url` " \
                               "advertises in /.well-known/kiosk.json, so this guard must not " \
                               "carry on without it — teach it where the default moved."
  end

  # ── String level: no sibling checkout, so this runs everywhere ─────────────
  #
  # bin/check-version-parity binds each of these URLs to the protocol's
  # MAJOR.MINOR and deliberately ignores PATCH (protocol.md §14.4 makes the
  # skill's PATCH an independent line). That leaves one thing unguarded and
  # this is it: the engine default may name a 0.3 cut that is not the cut the
  # demos pin — `skill-v0.3.2.md` passes version parity perfectly. A third
  # party inheriting the default would then advertise a superseded skill while
  # every demo in the same repo advertises the current one.
  it "is the same published cut in kiosk-server's default and in every demo" do
    skip "kiosk-server's default is unreadable (asserted above)" if default_url.nil?

    named = pins.transform_values { _1[:url] }.merge("kiosk-server (default)" => default_url)
    expect(named.values.uniq.size).to eq(1),
                                      "the skill_url consumers disagree on which cut is current:\n" \
                                      "#{named.map { |who, url| "  #{who}: #{url}" }.join("\n")}\n" \
                                      "All nine consumers re-pin together when a new skill is cut " \
                                      "(ADR-0012). bin/check-version-parity cannot see this — it " \
                                      "compares MAJOR.MINOR only, and every URL above is 0.3."
  end

  # ── Byte level: needs the published files, so umbrella checkouts only ──────
  describe "against the published bytes" do
    before do
      skip "sibling kiosk.tech checkout not present (public CI)" unless File.directory?(site_root)
    end

    # The engine default carries no sha256 of its own — `skill_sha256` is nil
    # until an operator sets it, and kiosk-server omits the whole `skill` block
    # rather than ship a stale hash. So the property to assert is that the file
    # it names is really published and is byte-identical to what the demos
    # verify against: the default and the pins must describe one artefact.
    it "kiosk-server's default names a published file, the same one the demos pin" do
      skip "kiosk-server's default is unreadable (asserted above)" if default_url.nil?

      file = File.join(site_root, File.basename(default_url))
      expect(File).to exist(file),
                      "kiosk-server defaults skill_url to #{default_url}, but " \
                      "#{File.basename(default_url)} is not published in #{site_root} — every " \
                      "operator who does not override it advertises a URL that 404s, and an AI " \
                      "assistant that cannot fetch the pinned skill cannot verify it."

      actual    = Digest::SHA256.hexdigest(File.binread(file))
      demo_shas = pins.values.filter_map { _1[:sha] }.uniq
      expect(demo_shas).to eq([actual]),
                           "the default cut #{File.basename(default_url)} hashes to #{actual}, " \
                           "but the demos pin #{demo_shas.inspect} — the default and the demo pins " \
                           "are supposed to be the same artefact. Re-pin them together, or publish " \
                           "a new immutable cut and move all nine consumers to it."
    end

    initializers.each do |path|
      demo = path[%r{(kiosk-demo-[^/]+)}, 1]

      it "#{demo} pins the sha256 of the published skill version file" do
        pin = pins[demo][:sha]
        expect(pin).not_to be_nil, "#{demo}: no skill_sha256 pin in #{path}"

        url = pins[demo][:url]
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

    # ── The cut the demos pin must TERMINATE its device-code poll (K-871) ────
    #
    # The account-binding ceremony is the third out-of-band completion poll,
    # and it was the one nobody bounded: the cut told an assistant to keep
    # polling on `authorization_pending`, to back off on `slow_down`, and
    # nothing else — so a ceremony the human DENIED, or one whose `expires_in`
    # elapsed, polled forever. Its two siblings were bounded deliberately
    # (K-477/K-595 wrote the cadence + horizon, K-606 gave them a gate that
    # reads the SERVED descriptor back off the wire). This ceremony has no
    # descriptor to read — it is not a catalog verb — so the artefact itself
    # is where the property can be asserted, and this spec is the one place
    # that already reads the published bytes.
    #
    # THE VOCABULARY IS DERIVED, NEVER LISTED. The engine is the authority on
    # which OAuth errors a poll can meet, so the expectation reads them out of
    # `DeviceCodeGrant`'s own `failure(:code, …)` calls. A code added there and
    # not taught to the skill fails here — which is the D3 drift this guards —
    # and a hand-kept list in a spec file would have been a second place the
    # vocabulary lives, the divergence K-605 closed by deleting one.
    it "the pinned cut names every device-grant error the engine can emit, and a give-up horizon" do
      grant_source = File.join(
        monorepo_root, "kiosk-server/lib/kiosk/server/device_code_grant.rb"
      )
      expect(File).to exist(grant_source)

      emitted = File.read(grant_source).scan(/failure\(:([a-z_]+)/).flatten.uniq
      # invalid_request is a malformed CALL (no device_code parameter), not an
      # outcome of a ceremony in progress: an assistant that sent no
      # device_code has a bug, not a poll to terminate.
      emitted -= %w[invalid_request]
      expect(emitted.size).to be >= 5,
                              "parsed only #{emitted.size} failure code(s) out of " \
                              "#{grant_source}; the call shape changed and this expectation is blind"

      url        = pins.values.filter_map { _1[:url] }.uniq.first
      skill_text = File.read(File.join(site_root, File.basename(url)))
      # The ceremony's own bullet and its sub-bullets, up to the sibling bullet.
      section = skill_text[/^- \*\*No code from the human\*\*.*?(?=^- \*\*The human hands you a code)/m]
      expect(section).not_to be_nil,
                             "could not locate the claim-ceremony bullet in #{File.basename(url)}"

      missing = emitted.reject { |code| section.include?(code) }
      expect(missing).to be_empty,
                         "#{File.basename(url)} teaches the device-code poll without naming " \
                         "#{missing.join(', ')} — the engine emits #{emitted.sort.join(', ')} " \
                         "(#{grant_source}), and an error the skill does not name is an error " \
                         "the assistant loops on"

      expect(section).to match(/GIVE UP/),
                         "#{File.basename(url)}'s device-code poll states no give-up horizon. " \
                         "Nothing pushes on approval, so a loop without one runs until the " \
                         "assistant's budget dies — the card-setup and KYC polls both say where " \
                         "to stop, and this is the third such poll."
      expect(section).to match(/TERMINAL/),
                         "#{File.basename(url)}'s device-code poll marks no outcome TERMINAL, " \
                         "so a denied or expired ceremony has no stated stop condition."
    end
  end
end
