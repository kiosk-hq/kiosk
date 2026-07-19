# frozen_string_literal: true

# The engine-drawn account-binding routes: a host that mounts
# Kiosk::Server::Engine at the configured mount_path gets the full claim +
# link surface without hand-writing routes. spec_helper requires
# kiosk/server before Rails exists, so the Engine class is materialised here
# by pulling in railties and re-`load`ing engine.rb — the same
# late-materialisation pattern as the controller specs.

require "active_support/all" # rails/engine leans on AS core_ext being present
require "rails/engine"
require "action_controller"

load File.expand_path("../../../lib/kiosk/server/engine.rb", __dir__)
# recognize_path resolves controller constants, so materialise the routed
# controllers too (their files guard on ActionController being defined).
%w[oauth_device_authorization_controller oauth_token_controller
   device_verify_controller auth_controller assistants_controller].each do |file|
  load File.expand_path("../../../lib/kiosk/server/#{file}.rb", __dir__)
end

RSpec.describe "Kiosk::Server::Engine routes" do
  def recognize(method, path)
    routes = Kiosk::Server::Engine.routes
    routes.finalize!
    routes.recognize_path(path, method: method)
  end

  it "draws the claim-flow wire: device_authorization + token + verify page" do
    expect(recognize(:post, "/oauth/device_authorization"))
      .to include(controller: "kiosk/server/oauth_device_authorization", action: "create")
    expect(recognize(:post, "/oauth/token"))
      .to include(controller: "kiosk/server/oauth_token", action: "create")
    expect(recognize(:get, "/oauth/device/verify"))
      .to include(controller: "kiosk/server/device_verify", action: "show")
    expect(recognize(:post, "/oauth/device/verify"))
      .to include(controller: "kiosk/server/device_verify", action: "create")
  end

  it "draws the link flow + unlink on the auth surface" do
    expect(recognize(:post, "/auth/link"))
      .to include(controller: "kiosk/server/auth", action: "link")
    expect(recognize(:post, "/auth/claim"))
      .to include(controller: "kiosk/server/auth", action: "claim")
    expect(recognize(:post, "/auth/unlink"))
      .to include(controller: "kiosk/server/auth", action: "unlink")
  end

  it "draws the «Link an assistant» page" do
    expect(recognize(:get, "/auth/assistants"))
      .to include(controller: "kiosk/server/assistants", action: "show")
    expect(recognize(:post, "/auth/assistants/link"))
      .to include(controller: "kiosk/server/assistants", action: "link")
    expect(recognize(:post, "/auth/assistants/unlink"))
      .to include(controller: "kiosk/server/assistants", action: "unlink")
  end
end
