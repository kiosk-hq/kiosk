# frozen_string_literal: true

require 'story_helper'
require 'kiosk/test_helpers/descriptor_examples'

RSpec.describe 'Discovering the hotel', type: :story do
  it 'an assistant that knows nothing finds out, without an account, what the hotel offers and how to book' do
    kiosk  = published('/.well-known/kiosk.json')['kiosk']
    schema = published('/kiosk/schema')

    expect(kiosk['capabilities']).to include('schema', 'queries', 'actions', 'pay', 'events')
    expect(kiosk['events_url']).to match(%r{\Aws://127\.0\.0\.1:\d+/kiosk/events\z})
    expect(schema['events'].pluck('name').sort).to eq(%w[booking_confirmation payment payment_setup])

    queries = schema['queries'].index_by { it['name'] }
    actions = schema['actions'].index_by { it['name'] }
    %w[properties availability my_bookings search_hotels hotel_detail].each do |name|
      expect(queries.dig(name, 'description')).to be_present, name
    end
    %w[reserve_room payment_setup].each do |name|
      expect(actions.dig(name, 'description')).to be_present, name
    end
    queries.values_at('search_hotels', 'hotel_detail').each do |descriptor|
      expect(descriptor.values_at('input_schema', 'example_params', 'example_row')).to all(be_present)
    end

    examples = Kiosk::TestHelpers::DescriptorExamples.of(schema)
    expect(examples.size).to be >= 4
    expect(examples.filter_map(&:violation)).to be_empty
  end

  describe 'the landing page' do
    it 'the landing page advertises the skill this origin pins' do
      pinned = published('/.well-known/kiosk.json').dig('kiosk', 'skill', 'url')
      expect(pinned).to match(%r{\Ahttps://kiosk\.tech/skill-v\d+\.\d+\.\d+\.md\z})

      page = Net::HTTP.get_response(URI("#{live_url}/"))
      expect(page.body[/<link\s+rel="kiosk"\s+href="([^"]*)"/, 1]).to eq(pinned)
      expect(page['Link'][/<([^>]*)>\s*;\s*rel="kiosk"/, 1]).to eq(pinned)
    end

    it 'answers an assistant in markdown, and robots.txt names the sitemap' do
      page = Net::HTTP.get_response(URI("#{live_url}/"), 'Accept' => 'text/markdown')
      expect([page.code, page.content_type]).to eq(['200', 'text/markdown'])
      expect(page.body).to include('/.well-known/kiosk.json')

      sitemap_url = Net::HTTP.get(URI("#{live_url}/robots.txt"))[/^Sitemap: (\S+)$/, 1]
      expect(sitemap_url).to eq("#{live_url}/sitemap.xml")
      expect(Net::HTTP.get(URI(sitemap_url))).to include("<loc>#{live_url}/</loc>")
    end

    it 'answers the type that Accept ranks first, and a browser gets HTML' do
      { 'text/markdown, */*' => 'text/markdown', 'text/markdown;q=1.0, */*;q=0.1' => 'text/markdown',
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' => 'text/html' }.each do |accept, type|
        page = Net::HTTP.get_response(URI("#{live_url}/"), 'Accept' => accept)
        expect([page.code, page.content_type, page['Vary']]).to eq(['200', type, 'Accept']), accept
      end
    end

    it 'loads its script and style from this origin only, as its Content-Security-Policy says' do
      page = Net::HTTP.get_response(URI("#{live_url}/"))
      expect(page['Content-Security-Policy']).to include("default-src 'self'; script-src 'self'; style-src 'self'")
      expect(page.body).not_to match(/<script(?![^>]*src=)|<style|\sstyle=/)
    end
  end
end
