# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# A stubbed host application rooted in a temporary directory.
module EventsCableSpecHelpers
  def host(env, config_for: nil)
    app = instance_double(Rails::Application)
    allow(app).to receive(:config_for).with(:cable).and_return(config_for)
    allow(Rails).to receive_messages(application: app, root: root, env: ActiveSupport::EnvironmentInquirer.new(env))
  end

  def write_cable_yml = root.join('config').tap(&:mkpath).join('cable.yml').write('')
end

RSpec.describe Kiosk::Server::EventsCable, '.cable_config' do
  include EventsCableSpecHelpers

  let(:root) { Pathname(Dir.mktmpdir) }

  after { FileUtils.rm_rf(root) }

  it 'serves one process with `async` outside production when the host has no config/cable.yml' do
    host('development')
    expect(described_class.cable_config).to eq('adapter' => 'async')
  end

  it 'refuses a production host with no config/cable.yml' do
    host('production')
    expect { described_class.cable_config }
      .to raise_error(Kiosk::Server::Errors::ConfigurationError, %r{no config/cable\.yml})
  end

  it "returns the environment's settings from config/cable.yml" do
    write_cable_yml
    host('production', config_for: { adapter: 'solid_cable', polling_interval: 0.1 })
    expect(described_class.cable_config).to eq('adapter' => 'solid_cable', 'polling_interval' => 0.1)
  end

  it 'refuses a config/cable.yml that names no adapter for the environment' do
    write_cable_yml
    host('production')
    expect { described_class.cable_config }
      .to raise_error(Kiosk::Server::Errors::ConfigurationError, /names no adapter for production/)
  end
end
