# frozen_string_literal: true

require 'test_helper'

class RobotsTest < ActionDispatch::IntegrationTest
  test "robots.txt states the site's AI-use preferences in both vocabularies" do
    robots = Rails.public_path.join('robots.txt').read

    assert_includes robots, "\nContent-Signal: search=yes, ai-input=yes, ai-train=no\n"
    assert_includes robots, "\nContent-Usage: search=y, ai-use=y, train-ai=n\n"
  end
end
