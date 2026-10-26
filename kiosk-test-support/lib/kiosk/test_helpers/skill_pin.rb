# frozen_string_literal: true

require 'kiosk/server'

module Kiosk
  module TestHelpers
    # Checks the skill pin of an origin. kiosk-server gives the skill URL, and
    # each kiosk-server release gives the URL of a new skill version. The
    # operator sets `skill_sha256`, the SHA-256 of that file, and tells this
    # check the skill version that the digest is for. When an update of
    # kiosk-server moves the skill to a different version, the check fails and
    # tells the operator how to make the new digest.
    module SkillPin
      VERSION_IN_URL = /skill-v(\d+\.\d+\.\d+)\.md\z/
      SHA256 = /\A\h{64}\z/

      module_function

      # nil when the pin is correct. Otherwise, what is wrong and what to do.
      def problem(hashed_version:, configuration: Kiosk.configuration)
        served = Kiosk::Configuration.new.skill_url
        version = served[VERSION_IN_URL, 1]
        return override(configuration.skill_url, served) unless configuration.skill_url == served
        return if hashed_version == version && configuration.skill_sha256.to_s.match?(SHA256)

        stale(served, version, hashed_version, configuration.skill_sha256)
      end

      def override(configured, served)
        "The configuration sets skill_url to #{configured}. kiosk-server gives the skill URL " \
          "(#{served}). Remove the line `c.skill_url = ...` from your configuration."
      end

      def stale(url, version, hashed_version, sha256)
        <<~MESSAGE
          #{cause(version, hashed_version, sha256)}
          Do these steps:
          1. Download the skill #{version} from kiosk.tech and calculate its SHA-256:
               curl -fsS #{url} | shasum -a 256
          2. Set `c.skill_sha256` in config/initializers/kiosk.rb to that digest.
          3. Set `hashed_version: '#{version}'` in this test.
        MESSAGE
      end

      def cause(version, hashed_version, sha256)
        if hashed_version != version
          "kiosk-server gives the skill #{version}, but skill_sha256 is the digest of the skill #{hashed_version}."
        elsif sha256.nil?
          "kiosk-server gives the skill #{version}, and skill_sha256 is not set."
        else
          "skill_sha256 is not a SHA-256 digest (64 hexadecimal characters): #{sha256.inspect}."
        end
      end

      # The Minitest assertion:
      #   include Kiosk::TestHelpers::SkillPin::Assertions
      #   assert_kiosk_skill_pin hashed_version: '0.6.25'
      module Assertions
        def assert_kiosk_skill_pin(hashed_version:)
          problem = SkillPin.problem(hashed_version:)
          assert(problem.nil?, problem)
        end
      end
    end
  end
end
