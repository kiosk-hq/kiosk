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
    # Not tombstoned, not 404-with-a-hint — absent from the table. Both names
    # therefore fall through to the constrained per-verb pair at the bottom
    # and are resolved against the registry like any other name, which is what
    # "there is exactly ONE wire surface" means at the routing layer.
    routes = Kiosk::Server::Engine.routes
    routes.finalize!
    paths = routes.routes.map { |route| route.path.spec.to_s }

    expect(paths).to include("/schema(.:format)", "/pay(.:format)")
    expect(paths.grep(%r{\A/(query|run)\b})).to be_empty

    expect(recognize(:post, "/query"))
      .to include(controller: "kiosk/server/verb", action: "create", kiosk_verb: "query")
    expect(recognize(:post, "/run"))
      .to include(controller: "kiosk/server/verb", action: "create", kiosk_verb: "run")
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

  # ── the 0.4 per-verb wire (T-068 slice 1) ────────────────────────────────

  describe "the per-verb wire" do
    it "draws GET <name> at the query half and POST <name> at the action half" do
      expect(recognize(:get, "/catalog"))
        .to include(controller: "kiosk/server/verb", action: "show", kiosk_verb: "catalog")
      expect(recognize(:post, "/create_order"))
        .to include(controller: "kiosk/server/verb", action: "create", kiosk_verb: "create_order")
    end

    it "lets EVERY reserved-plane route win by first-match" do
      # This IS design §3.2's reserved-word rule, enforced by Rails' own
      # route ordering rather than by a hand-kept literal list: the per-verb
      # pair is drawn last, so an operator who declares a verb called
      # `schema` or `pay` cannot shadow the wire — the wire answers, and the
      # declaration-time refusal (so they learn at boot) is the descriptor
      # slice's job.
      expect(recognize(:get,  "/schema")).to include(controller: "kiosk/server/wire")
      expect(recognize(:post, "/pay")).to    include(controller: "kiosk/server/wire")
    end

    it "reserves exactly the first segments it draws — and `query`/`run` left both" do
      # `RESERVED_NAMES` is the declaration-time half of the same rule, and
      # `bin/check-kiosk-names` holds it equal to the engine's drawn first
      # segments. The cutover deleted two routes, so it shed the two names.
      expect(Kiosk::Server::HandlerMixin::RESERVED_NAMES)
        .to eq(%w[agents auth oauth pay schema])
    end

    it "does not swallow the multi-segment reserved routes" do
      expect(recognize(:get,  "/auth/challenge")).to include(controller: "kiosk/server/auth")
      expect(recognize(:post, "/agents/kyc")).to include(controller: "kiosk/server/kyc_attestation")
      expect(recognize(:get,  "/.well-known/jwks.json")).to include(controller: "kiosk/server/jwks")
    end

    it "does not swallow openapi.json as the verb `openapi` in the `json` format" do
      # `/:kiosk_verb(.:format)` would match it. The derived document's route
      # is drawn above the pair, so the literal path wins — and an operator
      # verb literally called `openapi` still answers at `/openapi`, because
      # the reserved route needs the `.json`.
      expect(recognize(:get, "/openapi.json"))
        .to include(controller: "kiosk/server/open_api", action: "show")
      expect(recognize(:get, "/openapi"))
        .to include(controller: "kiosk/server/verb", action: "show", kiosk_verb: "openapi")
    end

    it "leaves a path that cannot be a verb name a routing 404" do
      # The constraint keeps it out of the controller entirely, so it never
      # becomes a 401 from the wire.
      ["/Catalog", "/create-order", "/9lives", "/_hidden"].each do |path|
        expect { recognize(:get, path) }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
