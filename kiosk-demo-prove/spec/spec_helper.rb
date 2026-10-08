# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rspec/rails"

load Rails.root.join("db/schema.rb") unless ActiveRecord::Base.connection.table_exists?("prove_requests")

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  # Roll each example back so the shared prove_requests table stays clean.
  #
  # EXCEPTION: `:real_concurrency` examples opt out. A genuine race needs the
  # racing threads to see a row across SEPARATE, real Postgres connections —
  # which requires it actually committed. Wrapping the whole example in one
  # open transaction on the main thread's connection would make it invisible
  # (MVCC) to every other connection those threads check out from the pool,
  # so the "race" would pass for the wrong reason (no row found) rather than
  # by exercising the atomic claim. Those examples clean up their own rows.
  config.around(:each) do |example|
    if example.metadata[:real_concurrency]
      example.run
    else
      ActiveRecord::Base.transaction do
        example.run
        raise ActiveRecord::Rollback
      end
    end
  end
end
