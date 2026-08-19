# frozen_string_literal: true
#
# Agent-side driver: PROVE search_hotels pagination + hotel_detail (T-042 / K-452).
#
# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the QUERY STRING — including `limit` and `cursor`, which are RESERVED names
# the wire always accepts and `search_hotels` deliberately does NOT declare
# (K-798). The two page shapes are what §8.4 says they are: a TRUNCATED page is
# the object `{"rows": […], "next": "<cursor>"}`, a COMPLETE one is the bare
# array every other non-paginating query answers.
#
# Registers a fresh agent (registration IS PoW-gated; equihash_register
# solves it transparently), then:
#   1. search_hotels with a small limit over the ~100-hotel catalogue → a FULL
#      page that carries a top-level `next` (truncated).
#   2. Echo `next` back as `cursor` → the FOLLOWING page (different rows).
#   3. A filtered search that fits in one page → a BARE ARRAY, no `next`
#      (complete).
#   4. hotel_detail on a summary row's property_id → a ONE-ROW ARRAY carrying
#      the full property (K-794: a detail-by-id query answers rows like any
#      other non-paginating query).
#
# Usage (invoked by rake demo:search — do not run standalone without the server):
#   SERVER_URL=http://127.0.0.1:3003 KIOSK_ISSUER=http://127.0.0.1:3003 \
#   bundle exec ruby script/search_flow.rb
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

# This file calls NOTHING but queries, so it needs no POST helper at all: on the
# 0.4 wire `search_hotels` and `hotel_detail` are both `GET /kiosk/<name>`. (The
# register handshake below drives its own full-URL lambdas.)
#
# One query call: the verb NAME is the path segment, its arguments the query
# string. Empty-valued params are dropped so `cursor: nil` sends nothing at all
# rather than `cursor=` (ABSENT ≠ EMPTY — the decoder keeps an empty string).
def query_json(name, params = {}, bearer: nil)
  uri = URI("#{SERVER}/kiosk/#{name}")
  pairs = params.reject { |_, v| v.nil? }
  uri.query = URI.encode_www_form(pairs) unless pairs.empty?
  headers = {}
  headers["Authorization"] = "Bearer #{bearer}" if bearer
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {})]
end

# THE TWO PAGE SHAPES, read the way the descriptor's `oneOf` declares them: a
# truncated page is `{rows, next}`, a complete one is the bare array. An
# assistant that always pages until `next` is gone reads both with these two
# lines and needs no other branch.
def page_rows(body) = body.is_a?(Hash) ? Array(body["rows"]) : Array(body)
def page_next(body) = body.is_a?(Hash) ? body["next"] : nil

# ── Register (register PoW solved transparently) ──────────────────────────────
#
# This file's query_json takes a verb name and a `bearer:` kwarg, not the
# (url, body, headers) shape the shared helper drives; give it full-URL
# adapter lambdas that carry an arbitrary headers hash (the register retry rides
# the Kiosk-PoW header).
require_relative "../lib/equihash_register"
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
# `limit` rides the query string as a RESERVED parameter: search_hotels does not
# declare it (K-798), the wire accepts it anyway and the decoder coerces it to
# an integer from ArgumentDecoder::RESERVED.
rc1, p1 = query_json("search_hotels", { limit: LIMIT }, bearer: token)
abort "search page1 failed (#{rc1}): #{JSON.generate(p1)}" unless rc1 == 200
page1_rows = page_rows(p1)
page1_next = page_next(p1)
page1_ids  = page1_rows.map { |r| r["property_id"] }
STDERR.puts "  Page 1: #{page1_rows.size} rows, next=#{page1_next.inspect}"

# ── 2. Echo `next` as `cursor` → the FOLLOWING page ─────────────────────────
rc2, p2 = query_json("search_hotels", { limit: LIMIT, cursor: page1_next }, bearer: token)
abort "search page2 failed (#{rc2}): #{JSON.generate(p2)}" unless rc2 == 200
page2_rows = page_rows(p2)
page2_ids  = page2_rows.map { |r| r["property_id"] }
STDERR.puts "  Page 2: #{page2_rows.size} rows, next=#{page_next(p2).inspect}"

# Are page 1 and page 2 disjoint (real paging, not the same slice)?
pages_disjoint = (page1_ids & page2_ids).empty?

# ── 3. A filtered search that fits one page → a BARE ARRAY, no `next` ───────
rc3, p3 = query_json("search_hotels",
  { neighbourhood: "Beşiktaş", min_stars: 4, max_price_cents: 30000 },
  bearer: token)
abort "filtered search failed (#{rc3}): #{JSON.generate(p3)}" unless rc3 == 200
filtered_rows      = page_rows(p3)
filtered_has_next  = !page_next(p3).nil?
filtered_is_array  = p3.is_a?(Array)
STDERR.puts "  Filtered: #{filtered_rows.size} rows, bare array? #{filtered_is_array}, " \
            "next present? #{filtered_has_next}"

# ── 4. hotel_detail on a summary row's property_id → a ONE-ROW ARRAY ────────
detail_id = page1_rows.first && page1_rows.first["property_id"]
rc4, p4 = query_json("hotel_detail", { property_id: detail_id }, bearer: token)
abort "hotel_detail failed (#{rc4}): #{JSON.generate(p4)}" unless rc4 == 200
detail_is_array = p4.is_a?(Array)
detail_row_count = Array(p4).size
detail = Array(p4).first || {}
detail_room_count = (detail["room_types"] || []).size
STDERR.puts "  Detail for id=#{detail_id}: #{detail["name"]}, #{detail_room_count} room type(s) " \
            "in a #{detail_row_count}-row array"

# ── 4b. hotel_detail for an id nobody has → the EMPTY ARRAY (K-794) ─────────
# The other half of "a detail-by-id query is still a query": nothing matched the
# id, so the answer is no rows — not a 404, and not a null the schema would have
# to admit.
rc5, p5 = query_json("hotel_detail", { property_id: 999_999_999 }, bearer: token)
STDERR.puts "  Detail for an unknown id: HTTP #{rc5}, #{p5.inspect}"

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
  filtered_is_array: filtered_is_array,
  detail_id:         detail_id,
  detail_name:       detail["name"],
  detail_room_count: detail_room_count,
  detail_is_array:   detail_is_array,
  detail_row_count:  detail_row_count,
  http_unknown_detail:      rc5,
  unknown_detail_is_array:  p5.is_a?(Array),
  unknown_detail_row_count: Array(p5).size,
)
