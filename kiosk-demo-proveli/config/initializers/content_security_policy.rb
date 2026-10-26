# frozen_string_literal: true

# The Content-Security-Policy header of every response that Rails draws. A page,
# and a page that the Kiosk engine draws, takes its scripts, styles and images
# from this origin only, and has no inline script or style. A form posts only
# to this origin, and only this origin can frame a page.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src     :self
    policy.script_src      :self
    policy.style_src       :self
    policy.object_src      :none
    policy.base_uri        :none
    policy.form_action     :self
    policy.frame_ancestors :self
  end
end
