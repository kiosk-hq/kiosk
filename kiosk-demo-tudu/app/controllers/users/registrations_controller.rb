# frozen_string_literal: true

module Users
  # SIGN-UP, with the one field that keeps a login address off the roster (K-950).
  #
  # Devise's `RegistrationsController` permits `email`, `password` and
  # `password_confirmation` and nothing else, by design — a strong-parameters
  # allowlist is not something a view can widen. tudu needs one more, because
  # `list_members` publishes `users.display_name` rather than `users.email` and
  # tudu is the fleet's only demo with open registration: a visitor who cannot
  # name themselves joins every household roster as `member-<hex>`, which is
  # safe but useless to the people who invited them.
  #
  # This is the WHOLE override. Sign-up, sign-out, the redirects and the failure
  # re-render are Devise's, untouched — the same shape as the K-533 sessions
  # signpost next door, which subclasses to change one answer and inherits the
  # rest. `display_name` carries no authorisation meaning whatsoever: it is not
  # unique, nothing looks an account up by it, and {User.public_name} is the
  # only thing that reads it.
  class RegistrationsController < Devise::RegistrationsController
    before_action :permit_display_name, only: %i[create update]

    private

    # The sanitizer is keyed by Devise's CEREMONY name, not by the Rails action
    # — `:sign_up` and `:account_update`, never `:create`/`:update`. Passing the
    # action name instead registers an allowlist for a ceremony that never runs,
    # so the parameter is silently dropped and the account is created with no
    # name at all: the sign-up succeeds, the form looks right, and the roster
    # publishes `member-<hex>` for somebody who typed one. That failure is
    # invisible without an assertion, which is what
    # `ChosenNameNeverTheAddress` in script/redteam_suite.rb is for — it caught
    # exactly this on the first run.
    DEVISE_CEREMONY = { "create" => :sign_up, "update" => :account_update }.freeze

    def permit_display_name
      devise_parameter_sanitizer.permit(DEVISE_CEREMONY.fetch(action_name), keys: [:display_name])
    end
  end
end
