# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rspec/rails"

# Load the SQL structure into the test DB if the table isn't there yet
# (schema_format = :sql; the prove_requests table lives in structure.sql).
begin
  ActiveRecord::Base.connection.execute("SELECT 1 FROM prove_requests LIMIT 1")
rescue ActiveRecord::StatementInvalid
  ActiveRecord::Base.connection.reconnect!
  sql = File.read(Rails.root.join("db/structure.sql"))
  ActiveRecord::Base.connection.execute(sql)
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  # Roll each example back so the shared prove_requests table stays clean.
  config.around(:each) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
