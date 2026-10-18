# frozen_string_literal: true

require 'active_support/concern'

module Kiosk
  # `include Kiosk::SkillLink` in a page controller: every answer carries
  # `Link: <skill_url>; rel="kiosk"`, the discovery signal for a client that
  # does not read HTML.
  module SkillLink
    extend ActiveSupport::Concern

    included do
      before_action { response.set_header('Link', %(<#{Kiosk.configuration.skill_url}>; rel="kiosk")) }
    end
  end
end
