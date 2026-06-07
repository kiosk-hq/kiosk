# frozen_string_literal: true

RSpec.describe Kiosk::RLS::DSL do
  subject(:host) { FakeMigration.new }

  describe "#enable_rls_on" do
    it "executes the canonical spec §7.4 sequence" do
      host.enable_rls_on :rentals do
        policy :select, using: "user_id = kiosk.current_user_id()"
        policy :insert, check: "user_id = kiosk.current_user_id() AND kiosk.current_role() = 'customer'"
        comment "Scooter rentals owned by the renting user."
      end

      expect(host.statements).to eq([
        %(ALTER TABLE "rentals" ENABLE ROW LEVEL SECURITY),
        %(GRANT SELECT, INSERT, UPDATE, DELETE ON "rentals" TO "app_role"),
        %(CREATE POLICY "rentals_select" ON "rentals" FOR SELECT USING (user_id = kiosk.current_user_id())),
        %(CREATE POLICY "rentals_insert" ON "rentals" FOR INSERT WITH CHECK (user_id = kiosk.current_user_id() AND kiosk.current_role() = 'customer')),
        %(COMMENT ON TABLE "rentals" IS 'Scooter rentals owned by the renting user.'),
      ])
    end

    it "raises if comment is missing (spec §7.5)" do
      expect {
        host.enable_rls_on(:rentals) { policy :select, using: "x" }
      }.to raise_error(ArgumentError, /comment/)

      expect(host.statements).to be_empty
    end

    it "respects app_role override per-call" do
      host.enable_rls_on :rentals, app_role: "ro_role" do
        policy :select, using: "x"
        comment "."
      end

      expect(host.statements).to include(
        %(GRANT SELECT, INSERT, UPDATE, DELETE ON "rentals" TO "ro_role"),
      )
    end

    it "interleaves sequence grants for SERIAL PKs" do
      host.enable_rls_on :rentals, sequences: %w[rentals_id_seq] do
        policy :select, using: "x"
        comment "."
      end

      expect(host.statements).to include(
        %(GRANT USAGE, SELECT ON SEQUENCE "rentals_id_seq" TO "app_role"),
      )
    end

    it "uses configured Kiosk.app_role by default" do
      Kiosk.configure { |c| c.app_role = "agent" }

      host.enable_rls_on :rentals do
        policy :select, using: "x"
        comment "."
      end

      expect(host.statements).to include(
        %(GRANT SELECT, INSERT, UPDATE, DELETE ON "rentals" TO "agent"),
      )
    end
  end

  describe "#add_kiosk_policy_to" do
    it "emits a single CREATE POLICY without touching surrounding state" do
      host.add_kiosk_policy_to :rentals, :select,
        using: "auditor = true"

      expect(host.statements).to eq([
        %(CREATE POLICY "rentals_select" ON "rentals" FOR SELECT USING (auditor = true)),
      ])
    end

    it "respects an explicit name override" do
      host.add_kiosk_policy_to :rentals, :select,
        name: "rentals_select_auditor", using: "x"

      expect(host.statements.first).to start_with(%(CREATE POLICY "rentals_select_auditor"))
    end
  end

  describe "#change_kiosk_policy_on" do
    it "emits DROP then CREATE for the same policy name" do
      host.change_kiosk_policy_on :rentals, :update,
        using: "u", check: "c"

      expect(host.statements).to eq([
        %(DROP POLICY IF EXISTS "rentals_update" ON "rentals"),
        %(CREATE POLICY "rentals_update" ON "rentals" FOR UPDATE USING (u) WITH CHECK (c)),
      ])
    end
  end

  describe "#remove_kiosk_policy_from" do
    it "emits DROP POLICY IF EXISTS with default name" do
      host.remove_kiosk_policy_from :rentals, :delete

      expect(host.statements).to eq([
        %(DROP POLICY IF EXISTS "rentals_delete" ON "rentals"),
      ])
    end

    it "respects a custom name" do
      host.remove_kiosk_policy_from :rentals, :delete, name: "legacy_rentals_delete"

      expect(host.statements.first).to include(%("legacy_rentals_delete"))
    end
  end

  describe "#rename_kiosk_policy_on" do
    it "renames using `from:` symbol (auto-prefixed) and `to:` string" do
      host.rename_kiosk_policy_on :rentals, from: :select, to: "rentals_select_owner_or_admin"

      expect(host.statements).to eq([
        %(ALTER POLICY "rentals_select" ON "rentals" RENAME TO "rentals_select_owner_or_admin"),
      ])
    end

    it "accepts a literal from: string when the original name isn't a default" do
      host.rename_kiosk_policy_on :rentals, from: "rentals_legacy", to: "rentals_new"

      expect(host.statements.first).to start_with(%(ALTER POLICY "rentals_legacy"))
    end
  end
end
