# frozen_string_literal: true

# robots.txt and sitemap.xml. Both name absolute URLs on this origin, so they are rendered per request.
class CrawlerController < ApplicationController
  def robots = render(formats: :text)
  def sitemap = render(formats: :xml)
end
