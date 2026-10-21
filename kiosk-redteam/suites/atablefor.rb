# frozen_string_literal: true

# Red-team battery for atablefor: attacks a running server and asserts every attack is refused.
# Usage, in kiosk-demo-atablefor with its bundle:
#   SERVER_URL=http://127.0.0.1:3002 bundle exec ruby ../kiosk-redteam/suites/atablefor.rb

require 'date'
require 'json'
require 'securerandom'
require 'uri'

require 'kiosk/redteam'
require 'kiosk/test_helpers/person'

SERVER = ENV.fetch('SERVER_URL')

# Two separate seeded diners: my_bookings and cancel_booking scope by account, not by assistant.
DIEGO = Kiosk::TestHelpers::Person.new(SERVER, email: 'diego@example.com', password: 'atablefor-demo-password')
                                  .links_a_newcomer.principal
BEA   = Kiosk::TestHelpers::Person.new(SERVER, email: 'bea@example.com', password: 'atablefor-demo-password')
                                  .links_a_newcomer.principal

DIEGO_UUID = DIEGO.user_id

# The assistants' calls; each pays the proof-of-work toll its access token owes.
WIRE = Kiosk::TestHelpers::Wire.new(base_url: SERVER, pay_tolls: true)

# Each assistant's token with the key it is bound to: the wire signs a DPoP proof per call.
AUTH_A = WIRE.dpop(DIEGO.token, DIEGO.rsa_key)
AUTH_B = WIRE.dpop(BEA.token, BEA.rsa_key)

BATTERY = Kiosk::Redteam::Battery.new

# Find an open (restaurant, table, seating) row for a 2-top across the
# aggregator, excluding any [restaurant_table_id, seating_at] pairs.
def open_slot(exclude = [])
  rc, avail = WIRE.get_json('/kiosk/availability', { party_size: 2 }, AUTH_A)
  abort "availability failed (#{rc}): #{JSON.generate(avail)} — run bin/rails db:reset" unless rc == 200
  rows = Array(avail).reject { |r| exclude.include?([r['restaurant_table_id'], r['seating_at']]) }
  slot = rows.first
  abort "no open table for a 2-top (excluding #{exclude.inspect})" unless slot
  slot
end

# Book an availability row as `auth`, optionally injecting extra args.
def book_slot(auth, slot, extra = {})
  WIRE.post_json('/kiosk/book_table',
                 { restaurant_table_id: slot.fetch('restaurant_table_id'),
                   seating_at: slot.fetch('seating_at'),
                   party_size: 2 }.merge(extra),
                 auth)
end

# Fixture: Diego's booking, the target of the cross-owner beats.
slot_a = open_slot
rc, diego_book = book_slot(AUTH_A, slot_a)
abort "A book_table failed (#{rc}): #{JSON.generate(diego_book)} — run bin/rails db:reset" unless rc == 200
diego_booking_id = diego_book['booking_id']
abort "no booking_id from A's booking: #{JSON.generate(diego_book)}" unless diego_booking_id

rc, b_mine = WIRE.get_json('/kiosk/my_bookings', {}, AUTH_B)
b_ids = Array(b_mine).map { |r| r['booking_id'] }
BATTERY.record('CrossTenantRead',
               rc == 200 && !b_ids.include?(diego_booking_id),
               "Bea's my_bookings #{b_ids.inspect} excludes Diego's #{diego_booking_id}")

# Bea books naming Diego's user_id; the refusal writes nothing, so the slot stays free for her real booking.
slot_b = open_slot([[slot_a['restaurant_table_id'], slot_a['seating_at']]])
rc, forged = book_slot(AUTH_B, slot_b, user_id: DIEGO_UUID)
refused = rc == 400 && forged['code'] == 'bad_request' && forged['detail'].to_s.include?('user_id')

rc_b, beas = book_slot(AUTH_B, slot_b)
bea_booking_id = beas['booking_id']
rc_a, a_mine = WIRE.get_json('/kiosk/my_bookings', {}, AUTH_A)
a_ids = Array(a_mine).map { |r| r['booking_id'] }
BATTERY.record('ForgedUserId',
               refused && rc_b == 200 && rc_a == 200 && !a_ids.include?(bea_booking_id),
               "forged user_id → #{rc}/#{forged['code'].inspect} (want 400/bad_request naming user_id); " \
               "Diego's bookings #{a_ids.inspect} exclude Bea's #{bea_booking_id.inspect}")

rc, = WIRE.post_json('/kiosk/cancel_booking',
                     { booking_id: diego_booking_id },
                     AUTH_B)
BATTERY.record('CrossOwnerCancel', rc == 403, "Bea cancel Diego's booking → #{rc} (want 403)")

MALFORMED_IDS = ['not-a-uuid', '1; DROP TABLE bookings', '', '  '].freeze
SQL_INTERNALS = ['::uuid', 'PG::', '22P02', 'invalid input syntax'].freeze

# The refusal echoes the value it got, so `supplied:` keeps the probe's own bytes from reading as a leak.
def uuid_guard_verdict(path, body_for)
  MALFORMED_IDS.map do |junk|
    args = body_for.call(junk)
    rc, body, scan = uuid_guard_probe(path, args)
    code = body['code']
    # Every typed refusal is 400/bad_request; only the detail ties it to this argument.
    ok = rc == 400 && code == 'bad_request' &&
         body['detail'].to_s.include?(args.key(junk).to_s) && !scan.leak?
    [ok, "#{junk.inspect}→#{rc}/#{code.inspect}#{leak_note(scan)}"]
  end
end

# The status, body and leak scan of one malformed-id probe.
def uuid_guard_probe(path, args)
  rc, body = WIRE.post_json(path, args, AUTH_A)
  [rc, body, Kiosk::Redteam::LeakScan.scan(body, SQL_INTERNALS, supplied: args)]
end

# What a probe report adds when the leak scan found something, or has a note.
def leak_note(scan)
  "#{" LEAK #{scan.leak}" if scan.leak}#{scan.note}"
end

cancel_probes = uuid_guard_verdict('/kiosk/cancel_booking', ->(junk) { { booking_id: junk } })
BATTERY.record('MalformedUuidArg', cancel_probes.all? { |ok, _| ok },
               "cancel_booking with a malformed booking_id → #{cancel_probes.map(&:last).join(', ')} " \
               '(want 400/"bad_request", a detail naming the argument, and no SQL internals)')

require 'openssl'
throwaway_pem = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
rc, = WIRE.post_json('/kiosk/oauth/register', { public_key: throwaway_pem })
BATTERY.record('RegisterWithoutJwks', rc == 400, "register with a PEM and no jwks → #{rc} (want 400 invalid_client_metadata)")

rc, = WIRE.get_json('/kiosk/availability', { party_size: 2 })
BATTERY.record('MissingAuth', rc == 401, "unauthenticated request → #{rc} (want 401)")

rc, = WIRE.get_json('/kiosk/availability', { party_size: 2 }, WIRE.dpop('not-a-real-token', DIEGO.rsa_key))
BATTERY.record('GarbageToken', rc == 401, "garbage token → #{rc} (want 401)")

# A copied token without its key buys nothing: as a bearer token, or with another key's DPoP proof.
rc_stolen_bearer, = WIRE.get_json('/kiosk/availability', { party_size: 2 }, 'Authorization' => "Bearer #{DIEGO.token}")
rc_stolen_key,    = WIRE.get_json('/kiosk/availability', { party_size: 2 }, WIRE.dpop(DIEGO.token, BEA.rsa_key))
BATTERY.record('StolenToken', rc_stolen_bearer == 401 && rc_stolen_key == 401,
               "stolen token as a bearer → #{rc_stolen_bearer}, with the thief's key → #{rc_stolen_key} (want 401 both)")

# A self-asserted `agent:u-…:a-…:r-…` bearer is no credential; the earned token is the control.
self_asserted = [
  ['real account + real agent, role escalated to owner',
   "agent:u-#{DIEGO_UUID}:a-#{DIEGO.agent_id}:r-owner"],
  ['wholly invented ids',
   "agent:u-#{SecureRandom.uuid}:a-#{SecureRandom.uuid}:r-owner"]
].map do |label, token|
  code, = WIRE.get_json('/kiosk/availability', { party_size: 2 }, WIRE.dpop(token, DIEGO.rsa_key))
  [code == 401, "#{label} → #{code}"]
end
rc_auth_ctl, = WIRE.get_json('/kiosk/availability', { party_size: 2 }, AUTH_A)
BATTERY.record('SelfAssertedTokenForgery',
               self_asserted.all? { |ok, _| ok } && rc_auth_ctl == 200,
               "self-asserted `agent:u-…:r-owner` bearer: #{self_asserted.map(&:last).join(', ')} " \
               '(want 401 each, unconditionally — this IS a local-environment server); ' \
               "CONTROL the earned token → #{rc_auth_ctl} (want 200)")

rc, = WIRE.get_json('/kiosk/frobnicate', {}, AUTH_A)
BATTERY.record('UnknownQuery', rc == 404, "unknown query → #{rc} (want 404)")

rc, = WIRE.post_json('/kiosk/nope', {}, AUTH_A)
BATTERY.record('UnknownAction', rc == 404, "unknown action → #{rc} (want 404)")

# `query` and `run` name no verb: a plain routing 404, the same with or without a bearer.
unregistered = %w[query run].flat_map do |name|
  authed = WIRE.request(:post, "/kiosk/#{name}", body: { name: 'availability', party_size: 2 },
                                                 headers: AUTH_A)
  anon   = WIRE.request(:post, "/kiosk/#{name}", body: { name: 'availability', party_size: 2 })
  [[authed.status == 404 && authed.body['code'].nil?, "#{name}→#{authed.status}"],
   [anon.status   == 404 && anon.body['code'].nil?,   "#{name}(anon)→#{anon.status}"]]
end
BATTERY.record('UnregisteredVerbIsOrdinaryRefusal',
               unregistered.all? { |ok, _| ok },
               "unregistered verb names #{unregistered.map(&:last).join(', ')} " \
               '(want a plain 404 with no problem-document code, bearer or not)')

res404 = WIRE.request(:get, '/kiosk/book_table', headers: AUTH_A)
BATTERY.record('MethodMismatch',
               res404.status == 404 && res404['allow'].nil? && res404.body['code'].nil?,
               "GET an action → #{res404.status} Allow=#{res404['allow'].inspect} " \
               '(want a plain 404, no Allow, no problem-document code)')

# A well-formed but unserved filter must be a 400 naming the valid values, never `200 []`.
# A past seating is refused by the instant it starts, so the past probe is 30 days back, not today.
FAR_FUTURE = (Date.today + 3650).iso8601
PAST_DATE  = (Date.today - 30).iso8601
invalid_filter_probes = [
  ['time=18:00 (valid pattern, not a seating)',
   { party_size: 2, time: '18:00' }, %w[19:00 20:00 21:00]],
  ["date=#{FAR_FUTURE} (valid date, past the horizon)",
   { party_size: 2, date: FAR_FUTURE }, ['upcoming seatings']],
  ["date=#{PAST_DATE} (valid date, BEHIND the horizon)",
   { party_size: 2, date: PAST_DATE }, ['upcoming seatings']],
  ['neighborhood=Atlantis (well-formed, unserved)',
   { party_size: 2, neighborhood: 'Atlantis' }, ['Alfama']],
  ['both filters, no overlap',
   { party_size: 2, time: '18:00', date: FAR_FUTURE }, %w[19:00 20:00 21:00]]
].map do |label, args, named|
  rc, resp = WIRE.get_json('/kiosk/availability', args, AUTH_A)
  code   = resp.is_a?(Hash) ? resp['code'] : nil
  detail = resp.is_a?(Hash) ? resp['detail'].to_s : ''
  names  = named.all? { |value| detail.include?(value) }
  ok = rc == 400 && code == 'bad_request' && names
  [ok, "#{label} → #{rc}/#{code.inspect}#{ok ? " naming #{named.join(', ')}" : "/#{JSON.generate(resp)[0, 160]}"}"]
end
rc_ctl, ctl = WIRE.get_json('/kiosk/availability', { party_size: 2 }, AUTH_A)
control_ok = rc_ctl == 200 && Array(ctl).any?
BATTERY.record('InvalidFilterIsNotAnEmptyList',
               invalid_filter_probes.all? { |ok, _| ok } && control_ok,
               "#{invalid_filter_probes.map(&:last).join(', ')}; CONTROL unfiltered → " \
               "#{rc_ctl}/#{rc_ctl == 200 ? Array(ctl).size : 0} rows " \
               '(want 400 bad_request naming the valid values for each filter, and a non-empty control)')

# book_table must refuse a seating availability never offers, at both ends of the horizon and in basic ISO.
horizon_slot = open_slot
BASIC_ISO = Time.now.strftime('%Y%m%dT%H%M%S%z')
horizon_probes = [
  ["seating_at=#{FAR_FUTURE}T20:00 (beyond the rolling horizon)", "#{FAR_FUTURE}T20:00:00+00:00", 'upcoming seating'],
  ["seating_at=#{PAST_DATE}T20:00 (BEHIND the rolling horizon)", "#{PAST_DATE}T20:00:00+00:00", 'already started'],
  ["seating_at=#{BASIC_ISO} (basic ISO-8601, not the published extended form)", BASIC_ISO, 'seating_at']
].map do |label, bad_seating, named|
  rc, resp = book_slot(AUTH_A, horizon_slot, seating_at: bad_seating)
  code   = resp.is_a?(Hash) ? resp['code'] : nil
  detail = resp.is_a?(Hash) ? resp['detail'].to_s : ''
  ok = rc == 400 && code == 'bad_request' && detail.include?(named)
  [ok, "#{label} → #{rc}/#{code.inspect}#{ok ? " naming #{named}" : "/#{JSON.generate(resp)[0, 160]}"}"]
end
rc_horizon_ctl, horizon_ctl = book_slot(AUTH_A, horizon_slot)
horizon_control_ok = rc_horizon_ctl == 200 && !horizon_ctl['booking_id'].to_s.empty?
BATTERY.record('BookOutsideOfferedHorizon',
               horizon_probes.all? { |ok, _| ok } && horizon_control_ok,
               "#{horizon_probes.map(&:last).join(', ')}; CONTROL same row at its published seating → " \
               "#{rc_horizon_ctl}/#{horizon_ctl['booking_id'].inspect} " \
               '(want 400 bad_request naming the horizon for each, and a confirmed control)')

# Wrong-typed arguments must be a typed 400 with no runtime or SQL vocabulary in the body.
SHAPE_LEAKS = ['NoMethodError', 'undefined method', 'TypeError',
               'no implicit conversion', '::uuid', '::integer', '::date', 'PG::',
               '22P02', 'invalid input syntax', 'ActiveRecord::', 'ActiveModel::'].freeze

INT_SHAPES = [true, false, [], {}, [1], { 'a' => 1 }, 'abc', nil, 1.5, '0x10'].freeze
NONSTRING  = [true, false, [], {}, [1], { 'a' => 1 }, nil, 20_260_826].freeze
# A query parameter declared integer takes only an integer literal, so "2.0" is refused here (§8.1 item 8).
QUERY_JUNK = ['abc', 'true', '1.5', '0x10', '', '2.0'].freeze

def shape_verdict(label, status, body, supplied: nil)
  scan = Kiosk::Redteam::LeakScan.scan(body, SHAPE_LEAKS, supplied: supplied)
  code = body.is_a?(Hash) ? body['code'] : nil
  ok   = status == 400 && code == 'bad_request' && !scan.leak?
  [ok, "#{label}→#{status}/#{code.inspect}#{leak_note(scan)}"]
end

shape_slot   = open_slot
shape_probes = []

INT_SHAPES.each do |v|
  %i[party_size restaurant_table_id].each do |arg|
    rc, body = book_slot(AUTH_A, shape_slot, arg => v)
    shape_probes << shape_verdict("book_table #{arg}=#{v.inspect}", rc, body, supplied: { arg => v })
  end
end
NONSTRING.each do |v|
  rc, body = book_slot(AUTH_A, shape_slot, seating_at: v)
  shape_probes << shape_verdict("book_table seating_at=#{v.inspect}", rc, body, supplied: { seating_at: v })
  rc, body = WIRE.post_json('/kiosk/cancel_booking', { booking_id: v }, AUTH_A)
  shape_probes << shape_verdict("cancel_booking booking_id=#{v.inspect}", rc, body, supplied: { booking_id: v })
end
QUERY_JUNK.each do |v|
  rc, body = WIRE.get_json('/kiosk/availability', { party_size: v }, AUTH_A)
  shape_probes << shape_verdict("availability party_size=#{v.inspect}", rc, body, supplied: { party_size: v })
end
# Bracket spellings Rack folds into an Array and a Hash; URI.encode_www_form cannot produce them.
['party_size%5B%5D=2', 'party_size%5Bx%5D=2'].each do |bracket|
  rc, body = WIRE.get_json("/kiosk/availability?#{bracket}", {}, AUTH_A)
  shape_probes << shape_verdict("availability #{bracket}", rc, body, supplied: bracket)
end

# party_size reaches a range comparison on an integer column, so a value past int4 must be refused.
BEYOND_INT4 = 2_147_483_648 # one past PostgreSQL `integer`
rc, body = book_slot(AUTH_A, shape_slot, party_size: BEYOND_INT4)
shape_probes << shape_verdict("book_table party_size=#{BEYOND_INT4}", rc, body, supplied: { party_size: BEYOND_INT4 })
rc, body = WIRE.get_json('/kiosk/availability', { party_size: BEYOND_INT4 }, AUTH_A)
shape_probes << shape_verdict("availability party_size=#{BEYOND_INT4}", rc, body, supplied: { party_size: BEYOND_INT4 })

# Control for the leak scan: a needle the probe itself sent and the handler echoes is not a breach.
ECHO_CONTROL = 'PG::22P02 invalid input syntax'
rc_echo, body_echo = WIRE.get_json('/kiosk/availability',
                                   { party_size: 2, neighborhood: ECHO_CONTROL }, AUTH_A)
ok_echo, detail_echo = shape_verdict(
  'availability neighborhood=<a value spelling three SHAPE_LEAKS> (leak-scan control)',
  rc_echo, body_echo, supplied: { party_size: 2, neighborhood: ECHO_CONTROL }
)
unless JSON.generate(body_echo).include?(ECHO_CONTROL)
  ok_echo = false
  detail_echo += ' [CONTROL VACUOUS: the refusal did not echo the value, so the ' \
                 'leak scan was never asked to tell an echo from a leak]'
end
shape_probes << [ok_echo, detail_echo]

rc_shape_book, shape_book = book_slot(AUTH_A, shape_slot)
rc_shape_cancel, = WIRE.post_json('/kiosk/cancel_booking',
                                  { booking_id: shape_book['booking_id'] }, AUTH_A)
rc_shape_avail, shape_avail = WIRE.get_json('/kiosk/availability', { party_size: 2 }, AUTH_A)
shape_control_ok = rc_shape_book == 200 && !shape_book['booking_id'].to_s.empty? &&
                   rc_shape_cancel == 200 && rc_shape_avail == 200 && Array(shape_avail).any?
BATTERY.record('HostileArgShapes',
               shape_probes.all? { |ok, _| ok } && shape_control_ok,
               "#{shape_probes.size} probes: #{shape_probes.reject { |ok, _| ok }.map(&:last).join(', ')}" \
               "#{'all 400/"bad_request", no leak' if shape_probes.all? { |ok, _| ok }}; " \
               "CONTROLS book→#{rc_shape_book} cancel→#{rc_shape_cancel} availability→#{rc_shape_avail}/" \
               "#{rc_shape_avail == 200 ? Array(shape_avail).size : 0} rows " \
               '(want a typed 400 for every probe, never a 5xx and never a 200, and three live controls)')

# §8.1 item 8: a body field declared integer accepts a whole-valued float, while the query refuses "2.0".
float_body_json = JSON.generate({ party_size: 2.0 })
rc_fq, body_fq  = WIRE.get_json('/kiosk/availability', { party_size: '2.0' }, AUTH_A)
float_slot      = open_slot
rc_fb, body_fb  = book_slot(AUTH_A, float_slot, party_size: 2.0)
query_half_ok   = rc_fq == 400 && body_fq['code'] == 'bad_request'
body_half_ok    = rc_fb == 200 && body_fb['party_size'] == 2 &&
                  !body_fb['booking_id'].to_s.empty?
sent_a_float    = float_body_json.include?('"party_size":2.0')
WIRE.post_json('/kiosk/cancel_booking', { booking_id: body_fb['booking_id'] }, AUTH_A) if body_half_ok
BATTERY.record('WholeValuedFloatBody',
               query_half_ok && body_half_ok && sent_a_float,
               "query ?party_size=2.0 → #{rc_fq}/#{body_fq['code'].inspect}; " \
               "body {\"party_size\": 2.0} → #{rc_fb}/party_size=#{body_fb['party_size'].inspect} " \
               "booking_id=#{body_fb['booking_id'].inspect}" \
               "#{' [PROBE VACUOUS: the request body did not carry a JSON float]' unless sent_a_float} " \
               '(want 400 on the query half and a party of TWO on the body half — ' \
               'spec Section 8.1 item 8, and it is INTENTIONAL that they differ)')

# The device-grant claim must not let a caller pick its own role; this origin declares one, so a skip is a breach.
BATTERY.scenario(
  Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
  client: Kiosk::TestHelpers::Assistant.new(base_url: SERVER),
  profile: Kiosk::Redteam::Profile.new(pow_difficulty: 1, declared_roles: %w[customer]),
  on_skip: :breach
)

exit BATTERY.report!
