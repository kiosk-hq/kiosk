# frozen_string_literal: true

# Sends a signed attestation to the operator's callback. A callback that does
# not answer 2xx is sent again with Rails' default `retry_on` schedule. The
# job lives in this process's memory, so a restart drops a pending retry.
class CallbackDeliveryJob < ApplicationJob
  # The operator's callback did not accept the attestation.
  class NotAccepted < StandardError; end

  retry_on NotAccepted

  # @return [true] when the callback answered 2xx
  def perform(callback_url:, request_id:, kyc_jws:, nonce:)
    status = CallbackPoster.deliver(callback_url:, request_id:, kyc_jws:, nonce:)
    raise NotAccepted, "#{callback_url} answered #{status.inspect}" unless (200..299).cover?(status)

    true
  end
end
