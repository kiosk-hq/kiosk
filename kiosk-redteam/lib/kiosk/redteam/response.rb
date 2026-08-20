# frozen_string_literal: true

module Kiosk
  module Redteam
    # Raw HTTP response from a Kiosk provider endpoint.
    #
    # @!attribute status [Integer] HTTP status code (e.g. 200, 201, 401, 403)
    # @!attribute body   [Hash]    parsed JSON body; empty Hash on parse failure
    # @!attribute pow_retried [Boolean] true when this answer came back from
    #   {Client}'s ONE bounded 402-PoW retry — i.e. the harness was told
    #   `pow_required`, solved every challenge and re-sent the identical
    #   request (K-760). It changes what a SECOND 402 means: not "this harness
    #   does not pay tolls" but "the toll was demanded again after it was
    #   paid", which is the difference between a capability gap and a provider
    #   behaviour. Defaults false, so every hand-built Response reads as the
    #   un-retried first answer it is.
    Response = Data.define(:status, :body, :pow_retried) do
      def initialize(status:, body:, pow_retried: false) = super
    end
  end
end
