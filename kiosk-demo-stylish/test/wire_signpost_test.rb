# frozen_string_literal: true

require "test_helper"

# An assistant at the human sign-in pages is pointed at the wire.
class WireSignpostTest < ActionDispatch::IntegrationTest
  setup    { ActionController::Base.allow_forgery_protection = true }
  teardown { ActionController::Base.allow_forgery_protection = false }

  test "a JSON sign-in without a CSRF token gets a 422 naming the discovery document" do
    post "/users/sign_in", params: { user: { email: "probe@example.com", password: "probe" } }, as: :json

    assert_response :unprocessable_entity
    assert_signpost "invalid_authenticity_token"
  end

  test "a JSON sign-out with no session gets a 401 naming the discovery document" do
    delete "/users/sign_out", as: :json

    assert_response :unauthorized
    assert_signpost "not_signed_in"
  end

  private

  def assert_signpost(code)
    error = response.parsed_body.fetch("error")
    assert_equal code, error["code"]
    assert_includes error["hint"], "#{request.base_url}/.well-known/kiosk.json"
  end
end
