# frozen_string_literal: true
#
# Agent-side driver: PROVE search_hotels pagination + hotel_detail (T-042 / K-452).
#
# THE 0.4 WIRE. A query is `GET <endpoint>/<query-name>` with its arguments in
# the QUERY STRING — including `limit` and `cursor`, which are RESERVED names
# the wire always accepts and `search_hotels` deliberately does NOT declare
# (K-798). There is ONE page shape since T-092: the BODY is always the bare
# array every query answers, and truncation is said in the RESPONSE HEADERS —
# `Link: <…?cursor=…>; rel="next"` (RFC 8288) plus `X-Total-Count`.
#
# Registers a fresh agent (registration IS PoW-gated; equihash_register
# solves it transparently), then:
#   1. search_hotels with a small limit over the ~100-hotel catalogue → a FULL
#      page: a bare array, a `Link` rel="next", and an X-Total-Count larger
#      than the page.
#   2. FOLLOW that link verbatim → the FOLLOWING page (different rows).
#   3. A filtered search that fits in one page → the same bare array with NO
#      `Link` at all (complete).
#   4. hotel_detail on a summary row's property_id → a ONE-ROW ARRAY carrying
#      the full property (K-794: a detail-by-id query answers rows like any
#      other query).
#   5. hotel_detail on an id nobody has → 404 not_found (T-090, spec §9.1:
#      that argument ADDRESSES a property, so an empty array would be a
#      false statement rather than an empty result).
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
  get_url(uri.to_s, bearer: bearer)
end

# Fetch an absolute URL — which is what following a `Link` target IS. Step 2
# calls this with the header's own URI and builds nothing, because that is the
# behaviour RFC 8288 buys and the behaviour skill.md now teaches.
def get_url(url, bearer: nil)
  uri = URI(url)
  headers = {}
  headers["Authorization"] = "Bearer #{bearer}" if bearer
  res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri, headers))
  [res.code.to_i, (JSON.parse(res.body) rescue {}), res]
end

# ONE page shape (T-092): the body is the array, always. What used to be a
# branch on `Hash` vs `Array` is gone with the object.
def page_rows(body) = Array(body)

# The `rel="next"` target out of an RFC 8288 `Link` field value, or nil.
# The field value is a COMMA-SEPARATED list of links, each `<uri>; params`, so
# this splits and selects by relation rather than assuming ours is the only
# one — which is what the spec tells an assistant to do.
def link_next(res)
  raw = res["Link"]
  return nil if raw.nil? || raw.empty?

  raw.split(",").each do |link|
    target = link[/<([^>]*)>/, 1]
    next if target.nil?
    return target if link =~ /rel\s*=\s*"?next"?/
  end
  nil
end

def total_count(res) = res["X-Total-Count"]&.to_i

# ── Register (register PoW solved transparently) ──────────────────────────────
#
# This file's query_json takes a verb name and a `bearer:` kwarg, not the
# (url, body, headers) shape the shared helper drives; give it full-URL
# adapter lambdas that carry an arbitrary headers hash (the register retry rides
# the Kiosk-PoW header).
require_relative "equihash_register"
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
rc1, p1, res1 = query_json("search_hotels", { limit: LIMIT }, bearer: token)
abort "search page1 failed (#{rc1}): #{JSON.generate(p1)}" unless rc1 == 200
page1_rows  = page_rows(p1)
page1_next  = link_next(res1)
page1_total = total_count(res1)
page1_ids   = page1_rows.map { |r| r["property_id"] }
STDERR.puts "  Page 1: #{page1_rows.size} rows, bare array? #{p1.is_a?(Array)}, " \
            "Link next=#{page1_next.inspect}, X-Total-Count=#{page1_total.inspect}"

# ── 2. FOLLOW the Link target verbatim → the FOLLOWING page ─────────────────
# Nothing is rebuilt here: the operator handed over a complete URI and the
# assistant fetches it. That is the whole of what RFC 8288 buys.
rc2, p2, res2 = get_url(page1_next.to_s, bearer: token)
abort "search page2 failed (#{rc2}): #{JSON.generate(p2)}" unless rc2 == 200
page2_rows = page_rows(p2)
page2_ids  = page2_rows.map { |r| r["property_id"] }
STDERR.puts "  Page 2: #{page2_rows.size} rows, Link next=#{link_next(res2).inspect}"

# Are page 1 and page 2 disjoint (real paging, not the same slice)?
pages_disjoint = (page1_ids & page2_ids).empty?

# ── 3. A filtered search that fits one page → the same array, NO Link ───────
rc3, p3, res3 = query_json("search_hotels",
  { neighbourhood: "Beşiktaş", min_stars: 4, max_price_cents: 30000 },
  bearer: token)
abort "filtered search failed (#{rc3}): #{JSON.generate(p3)}" unless rc3 == 200
filtered_rows      = page_rows(p3)
filtered_has_next  = !link_next(res3).nil?
filtered_is_array  = p3.is_a?(Array)
filtered_total     = total_count(res3)
STDERR.puts "  Filtered: #{filtered_rows.size} rows, bare array? #{filtered_is_array}, " \
            "Link next present? #{filtered_has_next}, X-Total-Count=#{filtered_total.inspect}"

# ── 4. hotel_detail on a summary row's property_id → a ONE-ROW ARRAY ────────
detail_id = page1_rows.first && page1_rows.first["property_id"]
rc4, p4, _res4 = query_json("hotel_detail", { property_id: detail_id }, bearer: token)
abort "hotel_detail failed (#{rc4}): #{JSON.generate(p4)}" unless rc4 == 200
detail_is_array = p4.is_a?(Array)
detail_row_count = Array(p4).size
detail = Array(p4).first || {}
detail_room_count = (detail["room_types"] || []).size
STDERR.puts "  Detail for id=#{detail_id}: #{detail["name"]}, #{detail_room_count} room type(s) " \
            "in a #{detail_row_count}-row array"

# ── 4b. hotel_detail for an id nobody has → 404 not_found (T-090) ──────────
# `property_id` ADDRESSES a property here, so the honest answer is that the
# property is not here — spec §9.1. The one-row ARRAY shape K-794 shipped is
# untouched by that; the two questions are independent.
rc5, p5, _res5 = query_json("hotel_detail", { property_id: 999_999_999 }, bearer: token)
STDERR.puts "  Detail for an unknown id: HTTP #{rc5}, code=#{p5["code"].inspect}"

# ── 4c. availability for the SAME unknown id → 404 too (T-090) ─────────────
# The pair that made this Phil's call: two verbs of one origin used to disagree
# about the same argument, one answering 404 and the other `200 []`.
rc6, p6, _res6 = query_json(
  "availability",
  { property_id: 999_999_999, check_in: "2026-09-01", check_out: "2026-09-03" },
  bearer: token,
)
STDERR.puts "  Availability for an unknown id: HTTP #{rc6}, code=#{p6["code"].inspect}"

# ── 4d. A FILTER that matched nothing → 200 with an EMPTY array (T-090) ────
# Spec §9.1 rule 3, and the OTHER side of the discriminator 4b/4c just proved.
# `neighbourhood` and `max_price_cents` FILTER a collection — they do not
# address an entity — so a combination nothing satisfies is an honest empty
# result, not a 404: the hotels exist, none of them is under a cent.
#
# THE PAIR IS THE TEST. Rule 2 and rule 3 differ only in what the argument DOES
# («address» vs «filter»), so a run that checked one without the other could
# not tell a correct origin from one that answers 404 to everything (or `200
# []` to everything). Both are driven here, on the same origin, in the same
# run.
rc7, p7, res7 = query_json("search_hotels",
  { neighbourhood: "Sultanahmet", max_price_cents: 1 }, bearer: token)
empty_rows  = page_rows(p7)
empty_total = total_count(res7)
STDERR.puts "  Filter matching nothing: HTTP #{rc7}, #{empty_rows.size} rows, " \
            "X-Total-Count=#{empty_total.inspect}"

# The control for it: DROP the impossible price and the same neighbourhood
# filter returns rows. Without this, "0 rows" would also be what a broken
# filter, a bad cursor or an empty seed produces.
rc8, p8, _res8 = query_json("search_hotels", { neighbourhood: "Sultanahmet" }, bearer: token)
control_rows = page_rows(p8)
STDERR.puts "  …control (same neighbourhood, no price cap): HTTP #{rc8}, #{control_rows.size} rows"

# ── 4e. A value OUTSIDE ITS DOMAIN → 400 NAMING THE VALID VALUES (§9.1 r1) ──
# The third branch of the rule, and the one an assistant recovers from without
# refetching the catalogue: `neighbourhood` is a declared enum, so a value that
# is not in it is a malformed REQUEST — not a filter that matched nothing, and
# not a missing resource. What makes the answer usable is that it lists what
# would have been accepted.
rc9, p9, _res9 = query_json("search_hotels", { neighbourhood: "Atlantis" }, bearer: token)
# `p9` is NOT assumed to be a problem document. An origin that dropped the enum
# answers 200 with an ARRAY here, and reaching into that with `p9["code"]` would
# abort this driver with a TypeError — a crash where the rake task wants a
# reported FAIL. Watched: removing the `enum:` from the descriptor produced
# exactly that abort before this line existed.
bad_problem = p9.is_a?(Hash) ? p9 : {}
bad_detail  = bad_problem["detail"].to_s
STDERR.puts "  Out-of-domain neighbourhood: HTTP #{rc9}, code=#{bad_problem["code"].inspect}, " \
            "detail=#{bad_detail.inspect}"

puts JSON.generate(
  http_page1:        rc1,
  http_page2:        rc2,
  http_filtered:     rc3,
  http_detail:       rc4,
  page1_count:       page1_rows.size,
  page1_next:        page1_next,
  page2_count:       page2_rows.size,
  pages_disjoint:    pages_disjoint,
  page1_total:       page1_total,
  page1_is_array:    p1.is_a?(Array),
  filtered_count:    filtered_rows.size,
  filtered_has_next: filtered_has_next,
  filtered_is_array: filtered_is_array,
  filtered_total:    filtered_total,
  detail_id:         detail_id,
  detail_name:       detail["name"],
  detail_room_count: detail_room_count,
  detail_is_array:   detail_is_array,
  detail_row_count:  detail_row_count,
  http_unknown_detail:      rc5,
  unknown_detail_code:      p5.is_a?(Hash) ? p5["code"] : nil,
  http_unknown_availability: rc6,
  unknown_availability_code: p6.is_a?(Hash) ? p6["code"] : nil,
  http_empty_filter:         rc7,
  empty_filter_is_array:     p7.is_a?(Array),
  empty_filter_count:        empty_rows.size,
  empty_filter_total:        empty_total,
  control_filter_count:      control_rows.size,
  http_bad_enum:             rc9,
  bad_enum_code:             bad_problem["code"],
  bad_enum_detail:           bad_detail,
  bad_enum_names_values:     %w[Sultanahmet Beyoğlu Kadıköy].all? { |v| bad_detail.include?(v) },
  bad_enum_echoes_bad_value: bad_detail.include?("Atlantis"),
)
