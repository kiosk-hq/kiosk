# frozen_string_literal: true

require 'kiosk/redteam/token_claims'
require 'kiosk/redteam/verdicts'
require 'kiosk/redteam/staging'

module Kiosk
  module Redteam
    # Base class for adversarial scenarios. Subclasses implement #call and
    # return a Verdict: blocked when the origin refused the attack, skipped
    # when the profile lacks the surface the scenario needs.
    class Scenario
      include Verdicts
      include Staging

      attr_reader :name

      def initialize(name:)
        @name = name
      end

      def call(client, profile)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      private

      # Changes a payload claim and keeps the original signature.
      def tamper_token(token)
        TokenClaims.tamper(token)
      end
    end
  end
end
