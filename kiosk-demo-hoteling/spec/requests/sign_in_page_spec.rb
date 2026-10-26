# frozen_string_literal: true

require 'spec_helper'

# The sign-in page a person reaches from the home page and from the assistants page.
RSpec.describe 'The sign-in page' do
  it 'is a whole document under the hoteling header' do
    get new_user_session_path

    expect(response).to have_http_status(:ok)
    page = response.parsed_body
    expect(page.at('head title').text).to eq('Sign in — hoteling')
    expect(page.at('header .logo')).to be_present
    expect(page.at("form[action='#{user_session_path}']")).to be_present
  end
end
