# frozen_string_literal: true

module Kiosk
  module Redteam
    # Represents an authenticated agent identity returned after successful
    # registration.  Holds the RSA private key so scenarios can sign or forge
    # mandates on behalf of this principal.
    #
    # @!attribute agent_id  [String]            server-issued agent UUID
    # @!attribute user_id   [String]            server-issued user UUID
    # @!attribute token     [String]            Bearer access token for Kiosk API calls
    # @!attribute rsa_key   [OpenSSL::PKey::RSA] RSA-2048 private key used to sign mandates
    Principal = Data.define(:agent_id, :user_id, :token, :rsa_key)
  end
end
