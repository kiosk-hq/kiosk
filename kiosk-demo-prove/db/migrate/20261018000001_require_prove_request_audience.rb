# frozen_string_literal: true

# Every request carries the audience its claim's `aud` binds to: the
# operator's registered audience, or its operator_id. A row written without
# one takes its operator_id, which is the `aud` its claim carried.
class RequireProveRequestAudience < ActiveRecord::Migration[8.1]
  def change
    up_only { execute('UPDATE prove_requests SET audience = operator_id WHERE audience IS NULL') }
    change_column_null :prove_requests, :audience, false
  end
end
