# frozen_string_literal: true

# Role-carrying stub USER-IdP for the roles-from-IdP demo (Path A).
#
# Stands in for the salon's own SSO / Okta: the provider's session tells
# Kiosk WHO the signed-in human is AND what role they hold. Where the Devise
# adapter reads the role off the Warden user, this reads it off a signed-in
# staff member identified by an `X-Staff-Session: <user_id>` header (the
# stand-in for an SSO session cookie), then looks up that staff member's
# `staff_role` in the provider's own users table.
#
# It returns a HUMAN {Kiosk::Identity} carrying `role: <staff_role>`. When the
# staff member mints a link code (POST /auth/link), kiosk-server captures that
# role onto the link row (AuthController#link → LinkCode.mint requested_role),
# so the assistant that redeems it INHERITS the human's role. This is the
# "a configured IdP supplies the human's role" seam, kept honest: the role
# comes from the provider's identity system, never from the agent.
#
# Only staff (staff_role present) resolve here — a customer or an unknown id
# yields nil, so this channel never mints link codes for non-staff. It is
# wired as one arm of a composite user_idp (StubUserIdp first, then the real
# Devise session) so demo:roles and demo:binding share one config.
class StubUserIdp < Kiosk::UserIdentityProviders::Base
  STAFF_HEADER = "X-Staff-Session"

  def verify(request)
    user_id = staff_session_for(request)
    return nil if user_id.nil? || user_id.empty?

    row = ActiveRecord::Base.connection.execute(
      "SELECT id, staff_role FROM users " \
      "WHERE id = #{ActiveRecord::Base.connection.quote(user_id)} " \
      "AND staff_role IS NOT NULL LIMIT 1",
    ).first
    return nil if row.nil?

    Kiosk::Identity.new(
      user_id:  row.fetch("id"),
      role:     row.fetch("staff_role"), # 'owner' — from the provider's IdP
      actor:    "human",
      agent_id: nil,
      claims:   {},
    )
  end

  private

  # The stand-in for an SSO session cookie: a header naming the signed-in
  # staff member. Read from whatever request shape the host passes.
  def staff_session_for(request)
    header =
      if request.respond_to?(:headers)
        request.headers[STAFF_HEADER] || request.headers["HTTP_X_STAFF_SESSION"]
      elsif request.is_a?(Hash)
        request["HTTP_X_STAFF_SESSION"] || request[STAFF_HEADER]
      end
    header.to_s
  end
end
