# frozen_string_literal: true

require 'test_helper'
require 'kiosk/test_helpers/descriptor_examples'

class DiscoveryStory < StoryTest
  test 'an assistant that knows nothing finds out, without an account, what the salon offers and how to book' do
    kiosk  = published('/.well-known/kiosk.json')['kiosk']
    schema = published('/kiosk/schema')

    assert_equal %w[actions queries schema], kiosk['capabilities'].sort
    assert_not kiosk.key?('events_url')
    assert_equal [], schema['events']

    queries = schema['queries'].index_by { it['name'] }
    actions = schema['actions'].index_by { it['name'] }

    assert_equal %w[my_appointments salon_calendar salons service_menu], queries.keys.sort
    assert_equal %w[book_appointment], actions.keys
    queries.merge(actions).each_value { assert_predicate it['description'], :present?, it['name'] }
    [queries['service_menu'], actions['book_appointment']].each do |descriptor|
      %w[input_schema example_params example_row].each { assert descriptor[it], "#{descriptor['name']} #{it}" }
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)

    assert_operator examples.size, :>=, 4
    assert_empty examples.filter_map(&:violation)
  end

  test 'the landing page advertises the skill this origin pins' do
    pinned = published('/.well-known/kiosk.json').dig('kiosk', 'skill', 'url')

    assert_match %r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z}, pinned

    page = Net::HTTP.get_response(URI("#{live_url}/"))

    assert_equal pinned, page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]
    assert_equal pinned, page['Link'][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]
  end

  test 'an assistant reads the landing page as markdown, and a crawler finds the sitemap in robots.txt' do
    page = Net::HTTP.get_response(URI("#{live_url}/"), 'Accept' => 'text/markdown')

    assert_equal ['200', 'text/markdown'], [page.code, page.content_type]
    assert_includes page.body, '/.well-known/kiosk.json'

    sitemap_url = Net::HTTP.get(URI("#{live_url}/robots.txt"))[/^Sitemap: (\S+)$/, 1]

    assert_equal "#{live_url}/sitemap.xml", sitemap_url
    sitemap = Net::HTTP.get(URI(sitemap_url))

    assert_includes sitemap, "<loc>#{live_url}/</loc>"
  end

  test "robots.txt states the site's AI-use preferences in both vocabularies" do
    robots = Net::HTTP.get(URI("#{live_url}/robots.txt"))

    assert_includes robots, "\nContent-Signal: search=yes, ai-input=yes, ai-train=no\n"
    assert_includes robots, "\nContent-Usage: search=y, ai-use=y, train-ai=n\n"
  end

  test 'the privacy page says what the demo stores and for how long, and the footer links it' do
    assert_includes Net::HTTP.get(URI("#{live_url}/")), '<a href="/privacy">Privacy</a>'

    privacy = Net::HTTP.get_response(URI("#{live_url}/privacy"))

    assert_equal '200', privacy.code
    assert_includes privacy.body, 'What Kiosk stores for an AI assistant'
    assert_includes privacy.body, 'How long we keep it'
    assert_not_includes privacy.body, "Stripe's test mode"
    assert_not_includes privacy.body, 'Identity checks'
  end

  test 'the landing page answers the type that Accept ranks first, and a browser gets HTML' do
    { 'text/markdown, */*' => 'text/markdown', 'text/markdown;q=1.0, */*;q=0.1' => 'text/markdown',
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' => 'text/html' }.each do |accept, type|
      page = Net::HTTP.get_response(URI("#{live_url}/"), 'Accept' => accept)

      assert_equal ['200', type, 'Accept'], [page.code, page.content_type, page['Vary']], accept
    end
  end

  test 'the landing page loads its script and style from this origin only, as its Content-Security-Policy says' do
    page = Net::HTTP.get_response(URI("#{live_url}/"))

    assert_includes page['Content-Security-Policy'], "default-src 'self'; script-src 'self'; style-src 'self'"
    assert_no_match(/<script(?![^>]*src=)|<style|\sstyle=/, page.body)
  end
end
