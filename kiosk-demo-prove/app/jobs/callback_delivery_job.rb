# frozen_string_literal: true

# Sends a signed attestation to the operator's callback. A callback that does
# not answer 2xx is sent again, each wait longer than the last. The job lives
# in this process's memory, so a restart drops a pending retry.
class CallbackDeliveryJob < ApplicationJob
  # The operator's callback did not accept the attestation.
  class NotAccepted < StandardError; end

  retry_on NotAccepted, wait: :polynomially_longer

  # @return [Integer] the 2xx status the callback answered
  def perform(callback_url:, request_id:, kyc_jws:, nonce:)
    status = CallbackPoster.deliver(callback_url:, request_id:, kyc_jws:, nonce:)
    raise NotAccepted, "#{callback_url} answered #{status.inspect}" unless (200..299).cover?(status)

    status
  end
end
