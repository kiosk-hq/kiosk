# frozen_string_literal: true

module Kiosk
  module Server
    # POST <endpoint>/kyc/callback — the KYC provider reports an approval.
    # Authenticated by the open request, its nonce and the signed attestation.
    class KycCallbackController < WireController
      def create
        Kyc.served!
        Kyc.callback(parse_body!)
        render json: { ok: true }, status: :ok
      end
    end
  end
end
