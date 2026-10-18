# frozen_string_literal: true

require 'test_helper'

class CallbackPosterTest < ActiveSupport::TestCase
  test 'posts an https callback over TLS' do
    http = CallbackPoster.http_for(URI('https://shop.example/kiosk/kyc/callback'))

    assert_predicate http, :use_ssl?
    assert_equal ['shop.example', 443], [http.address, http.port]
  end

  test 'connects to the IPv6 loopback without the brackets of its URL' do
    http = CallbackPoster.http_for(URI('http://[::1]:3004/kyc/callback'))

    assert_not_predicate http, :use_ssl?
    assert_equal ['::1', 3004], [http.address, http.port]
  end
end
