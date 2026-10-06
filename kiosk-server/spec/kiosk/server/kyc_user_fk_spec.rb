# frozen_string_literal: true

# KYC tables laid down without the user key gain it, against a real Postgres.

require "active_record"

RSpec.describe Kiosk::Server::SchemaDefinitions, ".kyc_user_fk_sql" do
  KYC_FK_SPEC_SCHEMA = "kiosk_kyc_fk_spec"

  before(:context) do
    ::ActiveRecord::Base.establish_connection(
      adapter: "postgresql", host: ENV["PGHOST"], username: ENV["PGUSER"],
      password: ENV["PGPASSWORD"], database: ENV.fetch("PGDATABASE", "postgres"),
    )
    ::ActiveRecord::Base.connection.execute("SELECT 1")
  rescue StandardError => e
    skip "no local Postgres reachable (#{e.class}: #{e.message})"
  end

  let(:conn) { ::ActiveRecord::Base.connection }

  def rows(table) = conn.select_values(%(SELECT user_id FROM "#{KYC_FK_SPEC_SCHEMA}".#{table} ORDER BY user_id))

  around do |example|
    conn.transaction do
      conn.execute(%(CREATE SCHEMA "#{KYC_FK_SPEC_SCHEMA}"; SET LOCAL search_path TO "#{KYC_FK_SPEC_SCHEMA}"))
      conn.execute(%(CREATE TABLE "#{KYC_FK_SPEC_SCHEMA}".people (id text PRIMARY KEY)))
      conn.execute(described_class.kyc_attributes_sql(schema: KYC_FK_SPEC_SCHEMA, user_id_type: :text,
                                                       user_table: "people"))
      %w[kyc_attributes kyc_requests].each do |table|
        conn.execute(%(ALTER TABLE "#{KYC_FK_SPEC_SCHEMA}".#{table} DROP CONSTRAINT #{table}_user_id_fkey))
      end
      conn.execute(%(INSERT INTO "#{KYC_FK_SPEC_SCHEMA}".people VALUES ('u-1'), ('u-2')))
      %w[u-1 u-2 gone].each do |id|
        conn.execute(%(INSERT INTO "#{KYC_FK_SPEC_SCHEMA}".kyc_attributes (user_id, name) VALUES ('#{id}', 'age_over_18')))
        conn.execute(%(INSERT INTO "#{KYC_FK_SPEC_SCHEMA}".kyc_requests (id, user_id, nonce) VALUES ('r-#{id}', '#{id}', 'n')))
      end
      example.run
      raise ::ActiveRecord::Rollback
    end
  end

  it "drops the rows of a person who no longer exists, then cascades every later delete" do
    conn.execute(described_class.kyc_user_fk_sql(schema: KYC_FK_SPEC_SCHEMA, user_table: "people"))
    expect([rows("kyc_attributes"), rows("kyc_requests")]).to eq([%w[u-1 u-2], %w[u-1 u-2]])

    conn.execute(%(DELETE FROM "#{KYC_FK_SPEC_SCHEMA}".people WHERE id = 'u-1'))
    expect([rows("kyc_attributes"), rows("kyc_requests")]).to eq([%w[u-2], %w[u-2]])
  end

  it "runs twice without failing" do
    2.times { conn.execute(described_class.kyc_user_fk_sql(schema: KYC_FK_SPEC_SCHEMA, user_table: "people")) }
  end
end
