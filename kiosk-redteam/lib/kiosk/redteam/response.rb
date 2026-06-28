# frozen_string_literal: true

module Kiosk
  module Redteam
    # Raw HTTP response from a Kiosk provider endpoint.
    #
    # @!attribute status [Integer] HTTP status code (e.g. 200, 201, 401, 403)
    # @!attribute body   [Hash]    parsed JSON body; empty Hash on parse failure
    Response = Data.define(:status, :body)
  end
end
