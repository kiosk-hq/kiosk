# frozen_string_literal: true

RSpec.describe Kiosk::Server::SchemaDefinitions do
  it "puts no KYC column on agents — the grants are the person's" do
    expect(described_class.identity_tables_sql).not_to include("kyc")
  end

  describe ".kyc_attributes_sql" do
    subject(:sql) { described_class.kyc_attributes_sql(schema: "kiosk", user_id_type: :bigint, user_table: "people") }

    it "keys the grants on the person, in the host's user id type" do
      grants = sql[/CREATE TABLE IF NOT EXISTS "kiosk"\.kyc_attributes.*?\);/m]
      expect(grants).to include(%(user_id    bigint NOT NULL REFERENCES "people"(id) ON DELETE CASCADE,))
      expect(grants).to include("PRIMARY KEY (user_id, name)")
      expect(grants).not_to include("agent_id")
    end

    # A jsonb map had to carry a VALUE, and a value has spellings. There is no
    # value column, so no reader decides which spelling of true counts.
    it "declares no value column — presence of the row IS the grant" do
      grants = sql[/CREATE TABLE IF NOT EXISTS "kiosk"\.kyc_attributes.*?\);/m]
      expect(grants).not_to include("boolean")
      expect(grants).not_to include("jsonb")
      expect(grants).not_to match(/\bvalue\b/)
    end

    it "lays down the verification requests beside them" do
      requests = sql[/CREATE TABLE IF NOT EXISTS "kiosk"\.kyc_requests.*?\);/m]
      expect(requests).to include("id          text PRIMARY KEY")
      expect(requests).to include(%(user_id     bigint NOT NULL REFERENCES "people"(id) ON DELETE CASCADE,))
      expect(requests).to include("nonce       text NOT NULL")
      expect(requests).to include("approved_at timestamptz")
    end

    it "uses the configured schema name and the configured user model's table" do
      stub_const("Person", Class.new { def self.table_name = "people" })
      Kiosk.configure do |c|
        c.schema     = "myschema"
        c.user_model = "Person"
      end
      expect(described_class.kyc_attributes_sql).to include('"myschema".kyc_requests', 'REFERENCES "people"(id)')
    end
  end
end
