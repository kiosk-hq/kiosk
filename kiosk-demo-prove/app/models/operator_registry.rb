# frozen_string_literal: true

require "uri"

# The operators this broker serves: each authenticates with its own secret,
# and the broker posts its callbacks to that operator's registered host only.
module OperatorRegistry
  module_function

  def registry = Rails.configuration.x.prove.operators

  def authenticate(operator_id:, secret:)
    operator = registry[operator_id.to_s]
    operator if operator && ActiveSupport::SecurityUtils.secure_compare(operator[:secret], secret.to_s)
  end

  def callback_allowed?(operator, callback_url)
    uri = URI.parse(callback_url.to_s)
    %w[http https].include?(uri.scheme) && uri.host.present? && uri.host == operator[:callback_host]
  rescue URI::InvalidURIError
    false
  end
end
