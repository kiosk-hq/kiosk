# frozen_string_literal: true

require 'test_helper'
require Rails.root.join('db/migrate/20261022100025_create_kiosk_assistant_accounts')

# The engine knows an assistant account only from the record that registration
# writes. A person who signs in through an outside identity provider may have no
# email here, and the migration does not take such an account for an assistant's.
class AssistantAccountsMigrationTest < ActiveSupport::TestCase
  setup do
    @alice, @bob, @carol = Array.new(3) { User.create!(email: nil) }
    @on_alice = agent_on(@alice)
    @on_carol = agent_on(@carol)
    ActiveRecord::Base.connection.execute('DROP TABLE "kiosk".assistant_accounts')
    CreateKioskAssistantAccounts.new.then { |migration| migration.suppress_messages { migration.up } }
  end

  def agent_on(user)
    ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      INSERT INTO "kiosk".agents (user_id, issuer) VALUES ('#{user.id}', '#{Kiosk.current_issuer}') RETURNING id
    SQL
  end

  def bind(agent, user) = Kiosk::Server::AccountBinding.bind!(agent_id: agent, user_id: user.id, requested_role: :customer)

  def assistant_accounts = ActiveRecord::Base.connection.select_rows('SELECT user_id, merged_into FROM "kiosk".assistant_accounts')

  test 'records no account that has no email' do
    assert_empty assistant_accounts
  end

  test 'merges nothing into an account with no email, and merges it into nothing' do
    bind(@on_carol, @alice)
    bind(@on_alice, @bob)

    assert_empty assistant_accounts
  end
end
