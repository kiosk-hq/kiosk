# frozen_string_literal: true

require "test_helper"

# The page a rental's `unlock_url` opens shows what the URL carries and nothing else.
class UnlockPageTest < ActionDispatch::IntegrationTest
  TOKEN = "skooti-rt-v1|SK-001|0f8c1d2e-6b1e-4a52-9f5e-1d2c3b4a5f60|1700000000|1700000900|jti-1.c2lnbmF0dXJl"

  setup { host! "127.0.0.1" }

  test "shows the QR of its own URL, the token and the vehicle, from no database read" do
    url = UnlockLink.url(origin: "http://127.0.0.1", scooter_code: "SK-001", rental_token: TOKEN)
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get url }

    assert_response :ok
    assert_includes response.body, UnlockLink.svg(url)
    assert_includes response.body, TOKEN
    assert_includes response.body, "SK-001"
    assert_empty queries
  end

  test "keeps the token out of caches, referrers and the request log" do
    get UnlockLink.url(origin: "http://127.0.0.1", scooter_code: "SK-001", rental_token: TOKEN)

    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("rt" => TOKEN)["rt"]
    assert_equal "x", filter.filter("cart" => "x")["cart"]
  end

  test "a URL missing either half is refused" do
    ["?scooter=SK-001", "?rt=#{CGI.escape(TOKEN)}", "?scooter=SK-001&rt[]=x"].each do |query|
      get "#{UnlockLink::PATH}#{query}"
      assert_response :bad_request, query
    end
  end
end
