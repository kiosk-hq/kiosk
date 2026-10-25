# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require_relative '../../lib/generators/kiosk/rls/install/install_generator'

RSpec.describe Kiosk::RLS::Generators::InstallGenerator do
  # The migration file the generator writes, for these arguments.
  def generate(*args)
    Dir.mktmpdir do |dir|
      stdout = $stdout
      $stdout = StringIO.new
      described_class.start(args, destination_root: dir)
      $stdout = stdout
      File.read(Dir[File.join(dir, 'db/migrate/*_create_kiosk_rls_functions.rb')].fetch(0))
    end
  end

  it 'creates the four kiosk_current_*() functions, and drops them on the way down' do
    body = generate
    %w[user_id role actor agent_id].each do |name|
      expect(body).to include("CREATE FUNCTION kiosk_current_#{name}()", "kiosk_current_#{name}()")
    end
    expect(body).to include('DROP FUNCTION kiosk_current_user_id(), kiosk_current_role(), ' \
                            'kiosk_current_actor(), kiosk_current_agent_id()')
  end

  it 'reads the GUCs kiosk-server sets, in the default namespace' do
    expect(generate).to include("current_setting('app.current_user_id', true)")
  end

  it 'reads the GUCs in the namespace it is given' do
    expect(generate('--guc-namespace=shop')).to include("current_setting('shop.current_agent_id', true)")
  end

  it "returns the user id in the operator's id type" do
    expect(generate('--user-id-type=bigint')).to include('kiosk_current_user_id() RETURNS bigint', "'')::bigint")
  end
end
