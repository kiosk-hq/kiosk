# frozen_string_literal: true

# The engine's route drawer (T-055 slice of K-495; closes K-505): a host that
# mounts Kiosk::Server::Engine at the configured mount_path gets the ENTIRE
# mount-prefixed surface — wire verbs, kiosk-pop auth plane, JWKS, KYC
# attestation, and the claim + link ceremony — without hand-writing routes.
# (The ROOT-relative discovery routes are installed by the engine's
# routes.append initializer into the HOST set, proven end-to-end in
# engine_mount_spec.rb.) `require "kiosk/server"` in spec_helper defines the
# Engine and the routed controllers outright — recognize_path resolves
# controller constants, so they have to be real.

RSpec.describe "Kiosk::Server::Engine routes" do
  def recognize(method, path)
    routes = Kiosk::Server::Engine.routes
    routes.finalize!
    routes.recognize_path(path, method: method)
  end

  it "draws the four wire verbs" do
    expect(recognize(:get, "/schema"))
      .to include(controller: "kiosk/server/wire", action: "schema")
    expect(recognize(:post, "/query"))
      .to include(controller: "kiosk/server/wire", action: "query")
    expect(recognize(:post, "/run"))
      .to include(controller: "kiosk/server/wire", action: "run")
    expect(recognize(:post, "/pay"))
      .to include(controller: "kiosk/server/wire", action: "pay")
  end

  it "draws the kiosk-pop auth plane" do
    expect(recognize(:get, "/auth/challenge"))
      .to include(controller: "kiosk/server/auth", action: "challenge")
    expect(recognize(:post, "/auth/register"))
      .to include(controller: "kiosk/server/auth", action: "register")
    expect(recognize(:post, "/auth/login"))
      .to include(controller: "kiosk/server/auth", action: "login")
    expect(recognize(:post, "/auth/revoke"))
      .to include(controller: "kiosk/server/auth", action: "revoke")
  end

  it "draws JWKS under the mount" do
    expect(recognize(:get, "/.well-known/jwks.json"))
      .to include(controller: "kiosk/server/jwks", action: "show")
  end

  it "draws the KYC attestation endpoint" do
    expect(recognize(:post, "/agents/kyc"))
      .to include(controller: "kiosk/server/kyc_attestation", action: "create")
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

  it "draws the «Link an assistant» page, including the update its form posts to" do
    expect(recognize(:get, "/auth/assistants"))
      .to include(controller: "kiosk/server/assistants", action: "show")
    expect(recognize(:post, "/auth/assistants/link"))
      .to include(controller: "kiosk/server/assistants", action: "link")
    expect(recognize(:post, "/auth/assistants/update"))
      .to include(controller: "kiosk/server/assistants", action: "update")
    expect(recognize(:post, "/auth/assistants/unlink"))
      .to include(controller: "kiosk/server/assistants", action: "unlink")
  end
end
