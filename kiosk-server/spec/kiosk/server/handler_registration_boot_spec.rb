# frozen_string_literal: true

# THE DEAD-ORIGIN GUARD. A mixin-declared verb registers when its class BODY IS
# READ; development does not eager-load `app/`, and nothing in a Kiosk app ever
# references a handler controller by name — the wire reaches it THROUGH the
# registry. So before the engine took registration over, an operator following
# the published onboarding got, in development:
#
#   GET  <mount>/schema            → queries=[] actions=[]
#   POST <mount>/query <any name>  → 404
#   GET  /.well-known/kiosk.json   → "capabilities": []
#
# — every verb missing and discovery advertising nothing, on day one. This
# pins the fix at the level it has to hold: a REAL booted Rails app, in both
# load modes, across REAL reload cycles (the third of which — a verb DELETED
# from its controller — is what a re-register-only implementation gets wrong).
#
# Out of process, one boot per scenario; see the probe's header.

require "open3"

module HandlerRegistrationProbe
  PROBE = File.expand_path("../../support/handler_registration_probe_app.rb", __dir__)

  def self.report(scenario)
    @reports ||= {}
    @reports[scenario] ||= begin
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, PROBE, scenario)
      unless status.success?
        raise "handler registration probe (#{scenario}) failed (#{status.exitstatus}):\n" \
              "--- stdout ---\n#{stdout}\n--- stderr ---\n#{stderr}"
      end
      JSON.parse(stdout)
    end
  end
end

RSpec.describe "handler registration in a booted app" do
  def probe(scenario, phase = "boot")
    HandlerRegistrationProbe.report(scenario).fetch(phase)
  end

  context "in development (eager_load = false), with the handlers declared" do
    it "has the full catalog at boot, before any request touches a controller" do
      expect(probe("development")["queries"]).to eq(%w[probe_browse probe_detail])
    end

    it "serves those names on the wire — the registry holds a real dispatch" do
      expect(probe("development")["browse_fetches"]).to eq("Kiosk::Server::HandlerDispatch")
    end

    it "advertises the capabilities computed from that catalog" do
      expect(probe("development")["capabilities"]).to include("schema", "queries")
    end

    it "picks up an EDITED description on reload, with no restart" do
      expect(probe("development", "after_edit").dig("descriptions", "probe_browse"))
        .to eq("EDITED without a restart.")
    end

    it "picks up an ADDED verb on reload" do
      after_add = probe("development", "after_add")
      expect(after_add["queries"]).to include("probe_added")
      expect(after_add["added_fetches"]).to eq("Kiosk::Server::HandlerDispatch")
    end

    it "drops a REMOVED verb from the catalog on reload" do
      expect(probe("development", "after_remove")["queries"]).to eq(%w[probe_detail])
    end

    it "stops serving a REMOVED verb on the wire, not just in the catalog" do
      # The leak a naive re-register-only to_prepare has: the descriptor
      # disappears while the previous generation's handler stays callable.
      expect(probe("development", "after_remove")["browse_fetches"]).to start_with("NotFound:")
    end

    # ── THE BOOT DIGEST (T-094) ─────────────────────────────────────────
    #
    # The catalog `GET <mount>/schema` serves is derived ONCE, by the engine,
    # in `after_initialize`, and served from memory afterwards. Phil asked for
    # the check to run in tests as well as in production («И на тестах чтобы
    # тоже»), and this is the only place in the suite that boots a real app —
    # so this is where it runs.
    it "derives the digest AT BOOT, not on the first request that asks" do
      expect(probe("development")["derived_at_boot"]).to be(true)
      expect(probe("development")["schema_digest"]).to match(/\A[0-9a-f]{32}\z/)
    end

    it "moves the digest on every reload that changes the catalog" do
      at_boot   = probe("development")["schema_digest"]
      edited    = probe("development", "after_edit")["schema_digest"]
      added     = probe("development", "after_add")["schema_digest"]
      removed   = probe("development", "after_remove")["schema_digest"]

      # A DESCRIPTION edit is the case a digest over verb NAMES alone would
      # miss — the roster is identical across this reload.
      expect(edited).not_to eq(at_boot)
      expect(added).not_to  eq(edited)
      expect(removed).not_to eq(added)
      expect([at_boot, edited, added, removed].uniq.size).to eq(4)
    end
  end

  context "in development with NO handlers declared" do
    it "registers nothing — declaring them is what registers them" do
      expect(probe("development_undeclared")["queries"]).to be_empty
      expect(probe("development_undeclared")["capabilities"]).to be_empty
    end

    it "says so in plain English when the wire is called anyway" do
      # "No querys are registered" was reachable in exactly this state, and
      # only here, which is how it survived to the T-057 pilot.
      expect(probe("development_undeclared")["browse_fetches"])
        .to include("No queries are registered.")
    end
  end

  context "in production (eager_load = true)" do
    it "still registers every handler it eager-loads, declared or not" do
      expect(probe("production")["queries"]).to eq(%w[probe_browse probe_detail])
      expect(probe("production")["browse_fetches"]).to eq("Kiosk::Server::HandlerDispatch")
    end

    it "registers each verb exactly once when the handlers are ALSO declared" do
      expect(probe("production_declared")["queries"]).to eq(%w[probe_browse probe_detail])
    end
  end
end
