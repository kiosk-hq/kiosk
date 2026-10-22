# frozen_string_literal: true

require 'kiosk/reputation'
require_relative '../../support/postgres'

# The first binding merges the assistant account into the human's account, so
# the human's recent spend counts the settlements and visits of the assistant
# account, in any window, also after the human unlinks the assistant.
RSpec.describe Kiosk::Server::AssistantAccounts do
  include_context 'with registered clients'
  include SettlementRows

  let(:conn)      { ActiveRecord::Base.connection }
  let(:schema)    { OauthClients::SCHEMA }
  let(:human)     { holder! }
  let(:assistant) { register_client(OpenSSL::PKey.generate_key('ED25519')) }

  before do
    defs = Kiosk::Server::SchemaDefinitions
    [defs.mandates_sql(schema:, user_id_type: :uuid), defs.visits_sql(schema:, user_id_type: :uuid), defs.refunds_sql(schema:),
     %(TRUNCATE "#{schema}".checkout_mandates, "#{schema}".visits CASCADE)].each { conn.execute(it) }
  end

  # The cents that `account` spent in the last `days`.
  def spend(account, days: 7) = Kiosk::Server::ReputationFactors.recent_spend(account, Time.current - (days * 86_400)).last

  def bind(client, account) = Kiosk::Server::AccountBinding.bind!(agent_id: client.id, user_id: account, requested_role: :customer)

  def paid_before_binding(cents, at: Time.current - 3600) = settle(cents, at:, account: assistant.user_id, agent: assistant.id)

  def visit(cents, account:, at: Time.current - 3600)
    conn.exec_query(%(INSERT INTO "#{schema}".visits (user_id, value_cents, visited_at) VALUES ($1, $2, $3)), 'spec', [account, cents, at])
  end

  it "counts what the assistant paid on its assistant account before the binding in the human's spend" do
    paid_before_binding(40_00)
    bind(assistant, human)

    expect(spend(human)).to eq(40_00)
  end

  it 'keeps counting it after the human unlinks the assistant' do
    paid_before_binding(40_00)
    bind(assistant, human)
    Kiosk::Server::AccountBinding.unlink!(agent_id: assistant.id, user_id: human)

    expect(spend(human)).to eq(40_00)
  end

  it 'counts the visits recorded on the assistant account' do
    visit(25_00, account: assistant.user_id)
    bind(assistant, human)

    expect(spend(human)).to eq(25_00)
  end

  it 'counts the rows of the assistant account older than a week in a longer window' do
    paid_before_binding(40_00, at: Time.current - (20 * 86_400))
    visit(25_00, account: assistant.user_id, at: Time.current - (20 * 86_400))
    bind(assistant, human)

    expect([spend(human), spend(human, days: 30)]).to eq([0, 65_00])
  end

  it 'merges no account of a human into the account of another human when a binding moves the assistant on' do
    other = holder!
    bind(assistant, human)
    settle(40_00, at: Time.current - 3600, account: human, agent: assistant.id)
    bind(assistant, other)

    expect([spend(human), spend(other)]).to eq([40_00, 0])
  end
end
