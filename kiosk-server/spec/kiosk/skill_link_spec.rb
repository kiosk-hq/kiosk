# frozen_string_literal: true

require 'rack/mock'

RSpec.describe Kiosk::SkillLink do
  let(:page) do
    Class.new(ActionController::Base) do
      include Kiosk::SkillLink

      def index = render(plain: 'ok')
    end
  end

  it 'answers every action with the pinned skill as a rel="kiosk" Link header' do
    Kiosk.configure { |c| c.skill_url = 'https://kiosk.tech/skill-v9.9.9.md' }
    _, headers, = page.action(:index).call(Rack::MockRequest.env_for('/'))

    expect(headers['Link']).to eq('<https://kiosk.tech/skill-v9.9.9.md>; rel="kiosk"')
  end
end
