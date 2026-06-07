# frozen_string_literal: true

RSpec.describe Kiosk::RLS::Emitter do
  describe ".enable_rls_sql" do
    it "emits ALTER TABLE ENABLE ROW LEVEL SECURITY" do
      expect(described_class.enable_rls_sql("rentals"))
        .to eq(%(ALTER TABLE "rentals" ENABLE ROW LEVEL SECURITY))
    end

    it "quotes schema-qualified table names per segment" do
      expect(described_class.enable_rls_sql("public.rentals"))
        .to eq(%(ALTER TABLE "public"."rentals" ENABLE ROW LEVEL SECURITY))
    end

    it "escapes embedded double-quotes in identifiers" do
      expect(described_class.enable_rls_sql(%(a"b)))
        .to eq(%(ALTER TABLE "a""b" ENABLE ROW LEVEL SECURITY))
    end
  end

  describe ".grant_table_sql" do
    it "GRANTs the four DML privileges to the runtime role" do
      expect(described_class.grant_table_sql("rentals", "app_role"))
        .to eq(%(GRANT SELECT, INSERT, UPDATE, DELETE ON "rentals" TO "app_role"))
    end
  end

  describe ".grant_sequence_sql" do
    it "GRANTs USAGE+SELECT on the sequence for the runtime role" do
      expect(described_class.grant_sequence_sql("rentals_id_seq", "app_role"))
        .to eq(%(GRANT USAGE, SELECT ON SEQUENCE "rentals_id_seq" TO "app_role"))
    end
  end

  describe ".create_policy_sql" do
    it "emits a SELECT policy with USING only" do
      policy = Kiosk::RLS::Policy.new(name: "rentals_select", action: :select, using: "user_id = 1")
      sql = described_class.create_policy_sql("rentals", policy)

      expect(sql).to eq(
        %(CREATE POLICY "rentals_select" ON "rentals" FOR SELECT USING (user_id = 1)),
      )
    end

    it "emits an INSERT policy with WITH CHECK only" do
      policy = Kiosk::RLS::Policy.new(name: "rentals_insert", action: :insert, check: "user_id = 1")
      sql = described_class.create_policy_sql("rentals", policy)

      expect(sql).to eq(
        %(CREATE POLICY "rentals_insert" ON "rentals" FOR INSERT WITH CHECK (user_id = 1)),
      )
    end

    it "emits an UPDATE policy with both USING and WITH CHECK" do
      policy = Kiosk::RLS::Policy.new(name: "rentals_update", action: :update, using: "u", check: "c")
      sql = described_class.create_policy_sql("rentals", policy)

      expect(sql).to eq(
        %(CREATE POLICY "rentals_update" ON "rentals" FOR UPDATE USING (u) WITH CHECK (c)),
      )
    end

    it "uppercases the action verb" do
      policy = Kiosk::RLS::Policy.new(name: "p", action: :all, using: "x")
      expect(described_class.create_policy_sql("t", policy)).to include("FOR ALL")
    end
  end

  describe ".drop_policy_sql" do
    it "emits DROP POLICY IF EXISTS" do
      expect(described_class.drop_policy_sql("rentals", "rentals_select"))
        .to eq(%(DROP POLICY IF EXISTS "rentals_select" ON "rentals"))
    end
  end

  describe ".rename_policy_sql" do
    it "emits ALTER POLICY ... RENAME TO" do
      expect(described_class.rename_policy_sql("rentals", "rentals_select", "rentals_select_owner"))
        .to eq(%(ALTER POLICY "rentals_select" ON "rentals" RENAME TO "rentals_select_owner"))
    end
  end

  describe ".comment_sql" do
    it "emits COMMENT ON TABLE with quoted string literal" do
      expect(described_class.comment_sql("rentals", "Rentals owned by the renting user."))
        .to eq(%(COMMENT ON TABLE "rentals" IS 'Rentals owned by the renting user.'))
    end

    it "escapes embedded single-quotes" do
      expect(described_class.comment_sql("t", "it's ok"))
        .to eq(%(COMMENT ON TABLE "t" IS 'it''s ok'))
    end
  end

  describe ".statements_for(table)" do
    it "emits the canonical spec §7.4 sequence (no sequences case)" do
      table = Kiosk::RLS::Table.new(:rentals)
      table.policy(:select, using: "user_id = kiosk.current_user_id()")
      table.policy(:insert, check: "user_id = kiosk.current_user_id()")
      table.comment("Rentals.")

      stmts = described_class.statements_for(table)

      expect(stmts).to eq([
        %(ALTER TABLE "rentals" ENABLE ROW LEVEL SECURITY),
        %(GRANT SELECT, INSERT, UPDATE, DELETE ON "rentals" TO "app_role"),
        %(CREATE POLICY "rentals_select" ON "rentals" FOR SELECT USING (user_id = kiosk.current_user_id())),
        %(CREATE POLICY "rentals_insert" ON "rentals" FOR INSERT WITH CHECK (user_id = kiosk.current_user_id())),
        %(COMMENT ON TABLE "rentals" IS 'Rentals.'),
      ])
    end

    it "interleaves sequence grants when sequences are declared" do
      table = Kiosk::RLS::Table.new(:rentals, sequences: %w[rentals_id_seq])
      table.policy(:select, using: "x")
      table.comment("Rentals with serial PK.")

      stmts = described_class.statements_for(table)

      expect(stmts[2]).to eq(
        %(GRANT USAGE, SELECT ON SEQUENCE "rentals_id_seq" TO "app_role"),
      )
    end

    it "omits the COMMENT when none was set (Emitter is permissive — Table#validate! enforces)" do
      table = Kiosk::RLS::Table.new(:rentals)
      table.policy(:select, using: "x")

      stmts = described_class.statements_for(table)

      expect(stmts.any? { |s| s.start_with?("COMMENT") }).to be(false)
    end
  end
end
