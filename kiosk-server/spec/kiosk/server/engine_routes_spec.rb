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

  it "draws the two RESERVED wire endpoints — and the wire has no others" do
    expect(recognize(:get, "/schema"))
      .to include(controller: "kiosk/server/wire", action: "schema")
    expect(recognize(:post, "/pay"))
      .to include(controller: "kiosk/server/wire", action: "pay")
    # `POST query` and `POST run` — 0.3's multiplexed pair — were DELETED at
    # the cutover (T-074 = A), so the controller they were drawn into has
    # exactly the two actions above left.
    expect(Kiosk::Server::WireController.action_methods.to_a).to match_array(%w[schema pay])
  end

  it "draws NO /query and NO /run: the 0.3 multiplexed pair is gone (T-074 = A)" do
    # Not tombstoned, not 404-with-a-hint — absent from the table. Nothing under
    # the mount matches either name, here or on a booted host: the engine draws
    # the protocol plane and nothing else, so both are the ordinary routing 404
    # any unrouted path gets. engine_mount_spec.rb asserts that end to end.
    routes = Kiosk::Server::Engine.routes
    routes.finalize!
    paths = routes.routes.map { |route| route.path.spec.to_s }

    expect(paths).to include("/schema(.:format)", "/pay(.:format)")
    expect(paths.grep(%r{\A/(query|run)\b})).to be_empty

    expect { recognize(:post, "/query") }.to raise_error(ActionController::RoutingError)
    expect { recognize(:post, "/run") }.to   raise_error(ActionController::RoutingError)
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

  # ── the 0.4 per-verb wire is NOT here any more (T-183) ───────────────────

  describe "the per-verb wire, which this table deliberately does NOT draw" do
    it "draws no dynamic segment at all — every path in it is a literal" do
      # The whole of T-183 at the routing layer. Until 0.4.12 this table ended
      # with `get "/:kiosk_verb"` / `post "/:kiosk_verb"`, and that pair SERVED
      # every registered verb. It is gone: the operator writes one explicit
      # route per verb in their own config/routes/kiosk.rb, GET for a query and
      # POST for an action, and this table is the PROTOCOL PLANE and nothing
      # else.
      routes = Kiosk::Server::Engine.routes
      routes.finalize!
      paths = routes.routes.map { |route| route.path.spec.to_s }

      expect(paths).not_to be_empty
      dynamic = paths.select { |path| path.match?(/[:*][a-z_]/) && !path.include?("(.:format)") }
      expect(dynamic).to be_empty
      expect(paths.grep(/kiosk_verb/)).to be_empty
    end

    it "leaves an operator verb name unroutable HERE — the mount cascades past it" do
      # A verb path matches nothing in this set, which is what lets the host's
      # own explicit line (drawn BELOW the mount) be reached at all: a mounted
      # route set that does not match answers `X-Cascade: pass` and the host's
      # router carries on. engine_mount_spec.rb proves the cascade end to end.
      expect { recognize(:get,  "/catalog") }.to      raise_error(ActionController::RoutingError)
      expect { recognize(:post, "/create_order") }.to raise_error(ActionController::RoutingError)
    end

    it "still owns every reserved path, and the mount being drawn FIRST is why" do
      # This IS spec §8.3's reserved-name rule. It used to be enforced by this
      # table's own ordering (the per-verb pair drawn last); it is now enforced
      # by the OPERATOR's file drawing `mount Kiosk::Server::Engine` above their
      # verbs, so every path here still wins by Rails' first-match.
      # `bin/check-verb-routes`' MOUNT-FIRST rule is what holds that ordering,
      # and {HandlerMixin::RESERVED_NAMES} refuses the declaration at boot so
      # the collision cannot be written in the first place.
      expect(recognize(:get,  "/schema")).to include(controller: "kiosk/server/wire")
      expect(recognize(:post, "/pay")).to    include(controller: "kiosk/server/wire")
    end

    it "reserves exactly the first segments it draws — and `query`/`run` left both" do
      # `RESERVED_NAMES` is the declaration-time half of the same rule, and
      # `bin/check-kiosk-names` holds it equal to the engine's drawn first
      # segments. The cutover deleted two routes, so it shed the two names;
      # `events` joined when the stream was mounted (T-169), which is the same
      # rule running the other way.
      expect(Kiosk::Server::HandlerMixin::RESERVED_NAMES)
        .to eq(%w[agents auth events oauth pay schema])
    end

    it "does not swallow the multi-segment reserved routes" do
      expect(recognize(:get,  "/auth/challenge")).to include(controller: "kiosk/server/auth")
      expect(recognize(:post, "/agents/kyc")).to include(controller: "kiosk/server/kyc_attestation")
      expect(recognize(:get,  "/.well-known/jwks.json")).to include(controller: "kiosk/server/jwks")
    end

    it "draws openapi.json as a literal, and nothing here answers /openapi" do
      # The `.json` document is the engine's; the bare `openapi` segment is a
      # legal verb name an operator may declare, and if they do it is THEIR
      # explicit route that serves it — not anything in this table.
      expect(recognize(:get, "/openapi.json"))
        .to include(controller: "kiosk/server/open_api", action: "show")
      expect { recognize(:get, "/openapi") }.to raise_error(ActionController::RoutingError)
    end
  end
end
