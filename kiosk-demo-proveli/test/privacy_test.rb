# frozen_string_literal: true

require 'test_helper'

class PrivacyTest < ActionDispatch::IntegrationTest
  test 'the footer links the privacy page' do
    get '/'

    assert_select 'footer a[href="/privacy"]', 'Privacy'
  end

  test 'the privacy page says what the broker stores and for how long' do
    get '/privacy'

    assert_response :ok
    assert_select 'h2', 3
    assert_includes response.body, 'We never store the facts you confirm'
  end
end
