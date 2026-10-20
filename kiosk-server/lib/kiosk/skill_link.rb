# frozen_string_literal: true

require 'active_support/concern'

module Kiosk
  # `include Kiosk::SkillLink` in a page controller: every answer carries
  # `Link: <skill_url>; rel="kiosk"`, the discovery signal for a client that
  # does not read HTML, and the RFC 9727 `api-catalog` link.
  module SkillLink
    extend ActiveSupport::Concern

    API_CATALOG = '</.well-known/api-catalog>; rel="api-catalog"'

    included do
      before_action do
        response.set_header('Link', %(<#{Kiosk.configuration.skill_url}>; rel="kiosk", #{API_CATALOG}))
      end
    end
  end
end
