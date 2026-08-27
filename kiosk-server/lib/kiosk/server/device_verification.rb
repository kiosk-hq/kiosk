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
    #   .approve(user_code:, user_id:, role:) — transition pending →
    #                                approved, capturing the approving
    #                                human's principal AND their role.
    #                                `role:` is REQUIRED — see below
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
    #
    # THAT INVITATION IS WHY `.approve` HAS NO DEFAULT FOR `role:` (K-1127).
    # A host that takes it up is writing the ONE step of the ceremony where an
    # authenticated human is present, and the role of the binding is decided
    # there or nowhere. While the keyword defaulted to `nil`, a bespoke page
    # that simply did not know about it produced role-less bindings silently —
    # the caller could not tell the omission from a deliberate "this approver
    # holds no role", and neither could the row. Naming it is now mandatory;
    # passing `nil` is still legal and still means the second of those two,
    # which is what an origin with a role-less `user_idp` genuinely reports.
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
      # holder's user_id AND their role. Raises {CodeNotFoundError} when no
      # pending row matches.
      #
      # `role:` IS THE CLAIM CEREMONY'S ROLE SOURCE (ADR-0011 amendment;
      # K-072). Pass `user_idp`'s `Identity#role` for the human whose session
      # is approving — the same value {AuthController#link} captures onto a
      # link row at mint. The claim row was created by an UNAUTHENTICATED
      # request and carries no role of its own, so this call is the only place
      # a claim ceremony can acquire one, and a bound assistant can therefore
      # never carry more than its approver holds.
      #
      # IT IS REQUIRED, AND IT STILL ACCEPTS `nil` (K-1127). The two are not in
      # tension: what is mandatory is SAYING what the approver holds, not that
      # they hold something. `role: nil` is the honest answer for an origin
      # whose `user_idp` reports no role, and it leaves the row role-less —
      # binding at `registration_role`/absent exactly as before, which is
      # ADR-0011's no-regression clause and is unchanged here. What is gone is
      # the third possibility: a caller who never considered the question and
      # got the role-less binding by default.
      #
      # Nothing in this repo relied on the old default. Its one engine caller
      # ({DeviceVerifyController}) has always passed the approving identity's
      # role, and the OTHER role-less `approve` — the one {LinkCode.mint}
      # calls without a role, legitimately, because a link row is minted BY the
      # human and already carries theirs — is {DeviceAuthorization#approve},
      # a different method on the value object. This module never sees a
      # `:link` row at all: {LinkCode.mint} stores its row already `:approved`,
      # and {.find_pending} returns only `:pending` ones.
      def approve(user_code:, user_id:, role:,
                  store: Kiosk.configuration.device_authorization_store)
        raise ArgumentError, "user_id required" if user_id.nil? || user_id.to_s.empty?

        da = find_pending(user_code: user_code, store: store)
        raise CodeNotFoundError, "user_code does not match any pending authorization" if da.nil?

        store.update(da.approve(user_id: user_id, role: role))
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
