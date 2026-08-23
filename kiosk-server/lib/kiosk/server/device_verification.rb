# frozen_string_literal: true

module Kiosk
  module Server
    # Pure-Ruby service module for the human-facing half of the claim
    # ceremony — i.e. what runs when the account holder lands at
    # `<endpoint>/oauth/device/verify` in their own browser.
    #
    # Three operations:
    #
    #   .find_pending(user_code:) — lookup by user_code with the visual
    #                                XXXX-XXXX dash stripped; only
    #                                pending rows are visible
    #   .approve(user_code:, user_id:) — transition pending → approved
    #   .deny(user_code:)           — transition pending → denied
    #
    # Codes are stored hashed only: the typed code is normalised, hashed
    # ({DeviceAuthorization.hash_user_code}) and matched against
    # `user_code_hash`.
    #
    # **Scope.** This module owns the state-machine half of verification
    # (the part that ALL providers do identically). The consent-screen UI
    # ships as {DeviceVerifyController} + minimal overridable engine views
    # (Devise-style batteries); a provider may also call these helpers from
    # its own controller for a fully bespoke page.
    module DeviceVerification
      # Raised when the user_code does not resolve to a pending row.
      # Distinct from {DeviceAuthorization::StateError} which signals a
      # logic error in the calling code; this one signals the *user*
      # entered a stale or wrong code.
      class CodeNotFoundError < StandardError; end

      module_function

      # Normalise, hash, then look up. Returns the {DeviceAuthorization} if
      # a pending row matches; `nil` otherwise. Callers render their own
      # "code not recognised" / "code expired" pages on `nil`.
      def find_pending(user_code:, store: Kiosk.configuration.device_authorization_store)
        normalized = normalize_user_code(user_code)
        return nil if normalized.empty?

        store.find_by_user_code_hash(DeviceAuthorization.hash_user_code(normalized))
      end

      # Transition pending → approved, stamping the approving account
      # holder's user_id. Raises {CodeNotFoundError} when no pending row
      # matches.
      def approve(user_code:, user_id:,
                  store: Kiosk.configuration.device_authorization_store)
        raise ArgumentError, "user_id required" if user_id.nil? || user_id.to_s.empty?

        da = find_pending(user_code: user_code, store: store)
        raise CodeNotFoundError, "user_code does not match any pending authorization" if da.nil?

        store.update(da.approve(user_id: user_id))
      end

      # Transition pending → denied.
      def deny(user_code:, store: Kiosk.configuration.device_authorization_store)
        da = find_pending(user_code: user_code, store: store)
        raise CodeNotFoundError, "user_code does not match any pending authorization" if da.nil?

        store.update(da.deny)
      end

      # User-typed codes arrive with the visual `XXXX-XXXX` dash + any
      # ambient whitespace from copy/paste. Storage hashes the raw 8-char
      # form, so normalise before hashing. Case-insensitive because some
      # keyboards / browsers auto-capitalise; we upcase into the
      # uppercase-only 31-char code alphabet
      # ({DeviceAuthorization::USER_CODE_ALPHABET}).
      def normalize_user_code(raw)
        raw.to_s.gsub(/[\s\-]/, "").upcase
      end
    end
  end
end
