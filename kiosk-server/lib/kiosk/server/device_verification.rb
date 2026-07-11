# frozen_string_literal: true

module Kiosk
  module Server
    # Pure-Ruby service module for the user-facing half of the RFC 8628
    # Device Authorization Grant — i.e. what runs when the user lands at
    # `<endpoint>/oauth/device/verify` from their phone / second device.
    #
    # Three operations:
    #
    #   .find_pending(user_code:) — lookup by user_code with the visual
    #                                XXXX-XXXX dash stripped; only
    #                                pending rows are visible
    #   .approve(user_code:, user_id:) — transition pending → approved
    #   .deny(user_code:)           — transition pending → denied
    #
    # **Scope.** This module owns the state-machine half of verification
    # (the part that ALL providers do identically). It does NOT own the
    # consent-screen UI, the host-app login integration, or the branded
    # "you're approved, return to your terminal" landing page — those
    # are provider responsibilities. The host's controller calls these
    # helpers from its own actions.
    #
    # @example Provider's Rails controller
    #   class DeviceVerificationController < ApplicationController
    #     before_action :authenticate_user!
    #
    #     def show
    #       @da = Kiosk::Server::DeviceVerification.find_pending(user_code: params[:user_code])
    #       render :consent if @da
    #     end
    #
    #     def approve
    #       Kiosk::Server::DeviceVerification.approve(
    #         user_code: params[:user_code], user_id: current_user.id,
    #       )
    #       render :approved
    #     end
    #   end
    module DeviceVerification
      # Raised when the user_code does not resolve to a pending row.
      # Distinct from {DeviceAuthorization::StateError} which signals a
      # logic error in the calling code; this one signals the *user*
      # entered a stale or wrong code.
      class CodeNotFoundError < StandardError; end

      module_function

      # Normalise then look up. Returns the {DeviceAuthorization} if a
      # pending row matches; `nil` otherwise. Callers render their own
      # "code not recognised" / "code expired" pages on `nil`.
      def find_pending(user_code:, store: Kiosk.configuration.device_authorization_store)
        normalized = normalize_user_code(user_code)
        return nil if normalized.empty?

        store.find_by_user_code(normalized)
      end

      # Transition pending → approved. Raises {CodeNotFoundError} when
      # no pending row matches.
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
      # ambient whitespace from copy/paste. Storage uses the raw 8-char
      # form, so normalise both before comparison. Case-insensitive
      # because some keyboards / browsers auto-capitalise; we upcase
      # against the Crockford alphabet.
      def normalize_user_code(raw)
        raw.to_s.gsub(/[\s\-]/, "").upcase
      end
    end
  end
end
