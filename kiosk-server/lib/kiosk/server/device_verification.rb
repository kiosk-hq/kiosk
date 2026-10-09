# frozen_string_literal: true

module Kiosk
  module Server
    # The human half of the claim ceremony: find, approve or deny a pending
    # authorization by the code the human typed. An operator's own consent
    # page may call these instead of {DeviceVerifyController}.
    module DeviceVerification
      # The human typed a wrong or expired code.
      class CodeNotFoundError < StandardError; end

      module_function

      def find_pending(user_code:, store: Kiosk.configuration.device_authorization_store)
        normalized = normalize_user_code(user_code)
        return nil if normalized.empty?

        store.find_by_user_code_hash(DeviceAuthorization.hash_user_code(normalized))
      end

      # `role:` is the approving human's own role (`user_idp`'s `Identity#role`,
      # nil when it reports none); it is required so a custom page cannot omit it by accident.
      def approve(user_code:, user_id:, role:,
                  store: Kiosk.configuration.device_authorization_store)
        raise ArgumentError, "user_id required" if user_id.nil? || user_id.to_s.empty?

        da = find_pending(user_code: user_code, store: store)
        raise CodeNotFoundError, "user_code does not match any pending authorization" if da.nil?

        store.update(da.approve(user_id: user_id, role: role))
      end

      def deny(user_code:, store: Kiosk.configuration.device_authorization_store)
        da = find_pending(user_code: user_code, store: store)
        raise CodeNotFoundError, "user_code does not match any pending authorization" if da.nil?

        store.update(da.deny)
      end

      # Drops the `XXXX-XXXX` dash and whitespace; the alphabet is uppercase.
      def normalize_user_code(raw)
        raw.to_s.gsub(/[\s\-]/, "").upcase
      end
    end
  end
end
