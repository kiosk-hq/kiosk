# frozen_string_literal: true

require 'uri'

# The operators this broker serves: each authenticates with its own secret,
# and the broker posts its callbacks to that operator's registered host only.
module OperatorRegistry
  # A callback travels over https; plain http only to the machine itself.
  LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze

  module_function

  def registry = Rails.configuration.x.proveli.operators

  def authenticate(operator_id:, secret:)
    operator = registry[operator_id.to_s]
    operator if operator && ActiveSupport::SecurityUtils.secure_compare(operator[:secret], secret.to_s)
  end

  def callback_allowed?(operator, callback_url)
    uri = URI.parse(callback_url.to_s)
    secure = uri.scheme == 'https' || (uri.scheme == 'http' && LOOPBACK_HOSTS.include?(uri.hostname))
    secure && uri.hostname.present? && uri.hostname == operator[:callback_host]
  rescue URI::InvalidURIError
    false
  end
end
