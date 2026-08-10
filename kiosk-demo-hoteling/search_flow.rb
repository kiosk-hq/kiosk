# frozen_string_literal: true
#
# Agent-side driver: PROVE search_hotels pagination + hotel_detail (T-042 / K-452).
#
# Registers a fresh agent (no PoW for hoteling), then:
#   1. search_hotels with a small limit over the ~100-hotel catalogue → a FULL
#      page that carries a top-level `next` (truncated).
#   2. Echo `next` back as `cursor` → the FOLLOWING page (different rows).
#   3. A filtered search that fits in one page → NO `next` (complete).
#   4. hotel_detail on a summary row's property_id → the full property (rooms present).
#
# Usage (invoked by rake demo:search — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3004 KIOSK_ISSUER=http://127.0.0.1:3004 \
#   bundle exec ruby search_flow.rb
#
# Prints ONE JSON line on stdout; non-zero exit on unexpected HTTP failures.

require "jwt"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

SERVER = ENV.fetch("SERVER_URL")
ISSUER = ENV.fetch("KIOSK_ISSUER")

def post_json(path, body, bearer: nil)
  uri = URI("#{SERVER}#{path}")
  headers = { "Content-Type" => "application/json" }
  headers["Authorization"] = "Bearer #{bearer}" if bearer
  req = Net::HTTP::Post.new(uri, headers)
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

def get_json(path)
  uri = URI("#{SERVER}#{path}")
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# ── Register (register PoW solved transparently) ──────────────────────────────
#
# This file's post_json/get_json take a `bearer:` kwarg and relative paths, not
# the (url, body, headers) shape the shared helper drives; give it full-URL
# adapter lambdas that carry an arbitrary headers hash (the register retry rides
# the Kiosk-PoW header).
require_relative "lib/equihash_register"
helper_get = ->(url) {
  uri = URI(url)
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
}
helper_post = ->(url, body, headers = {}) {
  uri = URI(url)
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = JSON.generate(body)
  res = Net::HTTP.new(uri.host, uri.port).request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
}
_key, reg = equihash_register(
  server: SERVER, issuer: ISSUER,
  get_json: helper_get, post_json: helper_post,
)
token = reg.fetch("access_token")
STDERR.puts "  Registered: user_id=#{reg["user_id"]}"

LIMIT = 20

# ── 1. Full first page → carries `next` (truncated) ─────────────────────────
rc1, p1 = post_json("/kiosk/query", { name: "search_hotels", limit: LIMIT }, bearer: token)
abort "search page1 failed (#{rc1}): #{JSON.generate(p1)}" unless rc1 == 200
page1_rows = p1["rows"] || []
page1_next = p1["next"]
page1_ids  = page1_rows.map { |r| r["property_id"] }
STDERR.puts "  Page 1: #{page1_rows.size} rows, next=#{page1_next.inspect}"

# ── 2. Echo `next` as `cursor` → the FOLLOWING page ─────────────────────────
rc2, p2 = post_json("/kiosk/query",
  { name: "search_hotels", limit: LIMIT, cursor: page1_next }, bearer: token)
abort "search page2 failed (#{rc2}): #{JSON.generate(p2)}" unless rc2 == 200
page2_rows = p2["rows"] || []
page2_ids  = page2_rows.map { |r| r["property_id"] }
STDERR.puts "  Page 2: #{page2_rows.size} rows, next=#{p2["next"].inspect}"

# Are page 1 and page 2 disjoint (real paging, not the same slice)?
pages_disjoint = (page1_ids & page2_ids).empty?

# ── 3. A filtered search that fits one page → NO `next` (complete) ───────────
rc3, p3 = post_json("/kiosk/query",
  { name: "search_hotels", neighbourhood: "Beşiktaş", min_stars: 4, max_price_cents: 30000 },
  bearer: token)
abort "filtered search failed (#{rc3}): #{JSON.generate(p3)}" unless rc3 == 200
filtered_rows      = p3["rows"] || []
filtered_has_next  = p3.key?("next")
STDERR.puts "  Filtered: #{filtered_rows.size} rows, next present? #{filtered_has_next}"

# ── 4. hotel_detail on a summary row's property_id → full property with rooms ─
detail_id = page1_rows.first && page1_rows.first["property_id"]
rc4, p4 = post_json("/kiosk/query", { name: "hotel_detail", property_id: detail_id }, bearer: token)
abort "hotel_detail failed (#{rc4}): #{JSON.generate(p4)}" unless rc4 == 200
detail = p4["rows"] || {}
detail_room_count = (detail["room_types"] || []).size
STDERR.puts "  Detail for id=#{detail_id}: #{detail["name"]}, #{detail_room_count} room type(s)"

puts JSON.generate(
  http_page1:        rc1,
  http_page2:        rc2,
  http_filtered:     rc3,
  http_detail:       rc4,
  page1_count:       page1_rows.size,
  page1_next:        page1_next,
  page2_count:       page2_rows.size,
  pages_disjoint:    pages_disjoint,
  filtered_count:    filtered_rows.size,
  filtered_has_next: filtered_has_next,
  detail_id:         detail_id,
  detail_name:       detail["name"],
  detail_room_count: detail_room_count,
)
