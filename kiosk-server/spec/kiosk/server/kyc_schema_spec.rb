# frozen_string_literal: true

RSpec.describe Kiosk::Server::SchemaDefinitions do
  describe ".kyc_verified_at_sql" do
    subject(:sql) { described_class.kyc_verified_at_sql }

    it "adds kyc_verified_at timestamptz to the agents table" do
      expect(sql).to include("ALTER TABLE")
      expect(sql).to include("kiosk")
      expect(sql).to include(".agents")
      expect(sql).to include("ADD COLUMN IF NOT EXISTS kyc_verified_at timestamptz")
    end

    it "uses the configured schema name" do
      Kiosk.configure { |c| c.schema = "myschema" }
      out = described_class.kyc_verified_at_sql
      expect(out).to include("myschema")
      expect(out).to include(".agents")
    end

    it "accepts explicit schema override" do
      out = described_class.kyc_verified_at_sql(schema: "custom")
      expect(out).to include('"custom".agents')
    end
  end
end
