# frozen_string_literal: true

require "kiosk/server/kyc"
require "kiosk/server/wire_controller"

module Kiosk
  module Server
    # POST <endpoint>/kyc/callback — the KYC provider reports an approved
    # verification: `{request_id, nonce, kyc_jws}`. Server to server, so it is
    # authenticated by the open request, its nonce and the signed attestation,
    # never by a session. `POST <endpoint>/request_kyc` is an ordinary verb,
    # served by {VerbController}.
    class KycCallbackController < WireController
      def create
        Kyc.served!
        Kyc.callback(parse_body!)
        render json: { ok: true }, status: :ok
      end
    end
  end
end
