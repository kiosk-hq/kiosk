# frozen_string_literal: true

require 'rack/mock'

RSpec.describe Kiosk::SkillLink do
  let(:page) do
    Class.new(ApplicationController) do
      include Kiosk::SkillLink

      def index = render(plain: 'ok')
    end
  end

  it 'answers every action with the pinned skill and the api-catalog as Link headers' do
    Kiosk.configure { |c| c.skill_url = 'https://kiosk.tech/skill-v9.9.9.md' }
    _, headers, = page.action(:index).call(Rack::MockRequest.env_for('/'))

    expect(headers['Link'])
      .to eq('<https://kiosk.tech/skill-v9.9.9.md>; rel="kiosk", </.well-known/api-catalog>; rel="api-catalog"')
  end
end
