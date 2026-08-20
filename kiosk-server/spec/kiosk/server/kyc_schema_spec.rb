# frozen_string_literal: true

RSpec.describe Kiosk::Server::SchemaDefinitions do
  # `kyc_verified_at` is no longer a generator of its own: K-646 folded it into
  # `identity_tables_sql`'s agents CREATE, where schema_definitions_spec asserts
  # it. What is asserted here is that the fold left nothing behind to call.
  it "no longer ships a kyc_verified_at generator — the column is in 002" do
    expect(described_class).not_to respond_to(:kyc_verified_at_sql)
    expect(described_class.identity_tables_sql).to include("kyc_verified_at     timestamptz")
  end

  describe ".kyc_attributes_sql" do
    subject(:sql) { described_class.kyc_attributes_sql }

    it "creates the kyc_attributes table keyed on (agent_id, name)" do
      expect(sql).to include("CREATE TABLE")
      expect(sql).to include('"kiosk".kyc_attributes')
      expect(sql).to include("PRIMARY KEY (agent_id, name)")
    end

    it "cascades from the agents row so a deleted agent takes its grants with it" do
      expect(sql).to include('REFERENCES "kiosk".agents(id) ON DELETE CASCADE')
    end

    # The property the move exists to buy (K-656): a jsonb map had to carry a
    # VALUE, and a value has spellings. There is no value column, so no reader
    # has to decide which spelling of true counts.
    it "declares no value column at all — presence of the row IS the grant" do
      expect(sql).not_to include("boolean")
      expect(sql).not_to include("jsonb")
      expect(sql).not_to match(/\bvalue\b/)
      expect(sql).not_to include("granted ")
    end

    it "uses the configured schema name" do
      Kiosk.configure { |c| c.schema = "myschema" }
      out = described_class.kyc_attributes_sql
      expect(out).to include('"myschema".kyc_attributes')
      expect(out).to include('REFERENCES "myschema".agents(id)')
    end

    it "accepts explicit schema override" do
      out = described_class.kyc_attributes_sql(schema: "custom")
      expect(out).to include('"custom".kyc_attributes')
    end
  end
end
