# frozen_string_literal: true

# The named vectors of the rental-token grammar: one or a few per rule on
# ../RENTAL_TOKEN.md, grouped by axis. token_vectors.rb loads this file and
# holds the primitives it uses.
module SkootiTokenVectors
  VECTORS = [
    # ── count: how many pipe-delimited fields the message carries ────────────
    v('count',  'six fields, well-formed',                  true, msg),
    v('count',  'five fields, jti absent',                  false,
      "kiosk-rental-v1|#{SCOOTER_CODE}|resv-live|#{IAT}|#{EXP}"),
    v('count',  'seven fields, one appended after the jti', false, msg(suffix: '|EXTRA')),
    v('count',  'eight fields, pipe-input shift, exp faked', false,
      "kiosk-rental-v1|#{SCOOTER_CODE}|r|#{IAT}|9999999999|#{IAT}|#{EXP}|#{JTI}"),
    v('count',  'seven segments, one trailing delimiter',   false, msg(suffix: '|')),
    v('count',  'eight segments, two trailing delimiters',  false, msg(suffix: '||')),
    v('count',  'seven segments, one leading delimiter',    false, "|#{msg}"),

    # ── empty: a field that is present but has no bytes ──────────────────────
    v('empty',  'empty scooter_code',                       false, msg(code: '')),
    v('empty',  'empty reservation_id',                     false, msg(resv: '')),
    v('empty',  'empty iat',                                false, msg(iat: '')),
    v('empty',  'empty exp',                                false, msg(exp: '')),
    v('empty',  'empty jti',                                false, msg(jti: '')),

    # ── tag: the domain-separation tag in field 0 ────────────────────────────
    v('tag',    'wrong tag, validly signed',                false, msg(tag: 'kiosk-rental-v0')),
    v('tag',    'right tag with a trailing space',          false, msg(tag: 'kiosk-rental-v1 ')),
    v('tag',    'right tag with a leading space',           false, msg(tag: ' kiosk-rental-v1')),
    v('tag',    'right tag in uppercase',                   false, msg(tag: 'KIOSK-RENTAL-V1')),

    # ── integer: what an iat or an exp may be spelled as ─────────────────────
    v('int',    'exp with a leading plus',                  false, msg(exp: "+#{EXP}")),
    v('int',    'exp with underscore separators',           false, msg(exp: '1_750_001_900')),
    v('int',    'exp with a leading space',                 false, msg(exp: " #{EXP}")),
    v('int',    'exp with a trailing space',                false, msg(exp: "#{EXP} ")),
    v('int',    'exp in hexadecimal',                       false, msg(exp: '0x684d84ec')),
    v('int',    'exp negative',                             false, msg(exp: '-1')),
    v('int',    'exp of 21 digits',                         false, msg(exp: '9' * 21)),
    v('int',    'exp of 21 digits, leading zeros, in window', false, msg(exp: "#{'0' * 11}#{EXP}")),
    v('int',    'exp of 20 digits, past UINT64_MAX',        false, msg(exp: '9' * 20)),
    v('int',    'exp of exactly UINT64_MAX',                true,  msg(exp: UINT64_MAX_S)),
    v('int',    'exp with leading zeros, in window',        true,  msg(exp: "00000000#{EXP}")),
    v('int',    'iat not a number',                         false, msg(iat: 'abc')),
    v('int',    'iat with a leading plus',                  false, msg(iat: "+#{IAT}")),
    v('int',    'iat of 21 digits',                         false, msg(iat: '9' * 21)),
    v('int',    'iat negative',                             false, msg(iat: '-5')),
    v('int',    'iat in non-ASCII digits',                  false, msg(iat: '١٧٥٠٠٠١٠٠٠')),
    v('int',    'iat of one digit',                         true,  msg(iat: '7')),
    v('int',    'iat equal to exp',                         true,  msg(iat: EXP)),
    v('int',    'iat far past exp',                         true,  msg(iat: '9999999999')),

    # ── jti: the replay key, and the only field with a fixed width ───────────
    v('jti',    'jti of 31 hex characters',                 false, msg(jti: JTI[0..-2])),
    v('jti',    'jti of 33 hex characters',                 false, msg(jti: "#{JTI}c")),
    v('jti',    'jti in uppercase hex',                     false, msg(jti: JTI.upcase)),
    v('jti',    'jti of 32 non-hex characters',             false, msg(jti: 'z' * 32)),
    v('jti',    'jti of 64 hex characters',                 false, msg(jti: JTI * 2)),

    # ── length: the length cap the lock enforces before it touches the parse ───
    v('length', 'token string at exactly 512 bytes',          true,  msg(resv: RESV_AT_CAP)),
    v('length', 'token string one byte over 512',             false, msg(resv: RESV_OVER)),

    # ── freshness: exp against the injected clock, boundary included ─────────
    v('fresh',  'exp one second past now',                  true,  msg(exp: (NOW + 1).to_s)),
    v('fresh',  'exp exactly now',                          false, msg(exp: NOW.to_s)),
    v('fresh',  'exp one second before now',                false, msg(exp: (NOW - 1).to_s)),
    v('fresh',  'exp strictly in the past',                 false, msg(exp: EXP_PAST)),
    v('fresh',  'iat exactly now',                          true,  msg(iat: NOW.to_s)),

    # ── sig: how the 64 signature bytes are spelled in the token string ──────────────
    v('sig',    'signature padded to 88 with equals signs', false, msg, :padded_sig),
    v('sig',    'signature in the standard base64 alphabet', false,
      msg(resv: RESV_ALPHABET), :standard_sig),
    v('sig',    'signature with a non-canonical last character', false, msg, :noncanonical_sig),
    v('sig',    'signature one character short',            false, msg, :short_sig),
    v('sig',    'signature one character long',             false, msg, :long_sig),
    v('sig',    'signature scalar moved up by the group order', false, msg, :malleated_sig),
    v('sig',    'signature scalar equal to the group order', false, msg, :order_sig),

    # ── wire: the shape of the token around the signature ────────────────────
    v('wire',   'no dot between message and signature',     false, msg, :no_dot),
    v('wire',   'empty signature half',                     false, msg, :empty_sig),
    v('wire',   'empty message half',                       false, msg, :empty_message),

    # ── bytes: what an opaque field may hold, byte for byte ──────────────────
    v('bytes',  'NUL inside reservation_id',                false, msg(resv: "resv#{NUL}live")),
    v('bytes',  'NUL inside scooter_code',                  false, msg(code: "#{SCOOTER_CODE}#{NUL}X")),
    v('bytes',  'NUL appended to the token string', false, msg, :trailing_nul),
    v('bytes',  'newline inside reservation_id',            false, msg(resv: "resv\nlive")),
    v('bytes',  'tab inside reservation_id',                false, msg(resv: "resv\tlive")),
    v('bytes',  '0x01 inside reservation_id',               false, msg(resv: "resv\u0001live")),
    v('bytes',  'DEL inside reservation_id',                false, msg(resv: "resv\u007Flive")),
    v('bytes',  'multibyte UTF-8 inside reservation_id',    false, msg(resv: 'resv-Ω-live')),

    # ── charset: the 66 characters fields 1 and 2 may hold ───────────────────
    # Named cases, readable beside the exhaustive SWEEP below. The alphabet
    # vector is the one that proves the set is admitted WHOLE rather than
    # approximately: every one of the 66 in a single reservation id.
    v('charset', 'reservation_id of the whole unreserved alphabet', true,
      msg(resv: UNRESERVED.map(&:chr).join)),
    v('charset', 'reservation_id of a canonical uuid',     true,
      msg(resv: 'ae01a0ae-336f-494f-b226-a006baee0947')),
    v('charset', 'space inside reservation_id',            false, msg(resv: 'resv live')),
    v('charset', 'percent sign inside reservation_id',     false, msg(resv: 'resv%live')),
    v('charset', 'plus sign inside reservation_id',        false, msg(resv: 'resv+live')),
    v('charset', 'slash inside reservation_id',            false, msg(resv: 'resv/live')),
    v('charset', 'space inside scooter_code',              false, msg(code: 'SK 001')),
    v('charset', '0xFF inside scooter_code',               false,
      msg(code: "SK#{255.chr(Encoding::BINARY)}-001")),

    # ── encoding: the Ruby tag the token is handed over under ────────────────
    # C sees bytes and answers the same six times; the two Ruby readers must
    # too. This axis is the reason Vector carries a `tag` at all, and it exists
    # because the answer to the canonical token USED to depend on it.
    *ENCODING_TAGS.map do |tag|
      v('encoding', "the canonical token tagged #{tag}", true, msg, :canonical, tag)
    end,
    *ENCODING_TAGS.map do |tag|
      v('encoding', "0xFF in reservation_id tagged #{tag}", false,
        msg(resv: "re#{255.chr(Encoding::BINARY)}sv"), :canonical, tag)
    end
  ].freeze
end
