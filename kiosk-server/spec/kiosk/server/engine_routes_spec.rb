# frozen_string_literal: true

# The engine-drawn account-binding routes: a host that mounts
# Kiosk::Server::Engine at the configured mount_path gets the full claim +
# link surface without hand-writing routes. `require "kiosk/server"` in
# spec_helper defines the Engine and the routed controllers outright —
# recognize_path resolves controller constants, so they have to be real.

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
