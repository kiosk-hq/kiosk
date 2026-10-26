# frozen_string_literal: true

require 'test_helper'

# The sign-in page a person reaches from the header and from the assistants page.
class SignInPageTest < ActionDispatch::IntegrationTest
  test 'is a whole document under the tudu header' do
    get new_user_session_path

    assert_select 'head title', 'tudu — collaborative todo (Kiosk demo)'
    assert_select 'header .logo'
    assert_select 'form[action=?]', user_session_path
  end
end
