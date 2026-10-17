# frozen_string_literal: true

require 'strscan'

# Reads Ruby source as text. It knows double- and single-quoted literals and
# their backslash escapes. It does not know heredocs, percent literals or the
# `?#` character literal.
module RubySourceText
  # A quoted literal, closed or running to the end of the text.
  STRING = /"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?/m

  BRACKETS = { '{' => 1, '[' => 1, '}' => -1, ']' => -1 }.freeze

  KEY = /([a-z_][a-z0-9_]*):(?!:)/

  module_function

  # Ruby line comments removed. Everything else stays byte-identical, newlines
  # included, so a line-anchored regex still sees the same lines.
  def without_comments(text)
    text.gsub(/#{STRING}|#[^\n]*/o) { |token| token.start_with?('#') ? '' : token }
  end

  # One or more adjacent quoted literals starting at `pos`, joined.
  def adjacent_strings(text, pos)
    parts = []
    loop do
      pos += 1 while pos < text.length && (text[pos].match?(/\s/) || text[pos] == '\\')
      quote = text[pos]
      break unless ['"', "'"].include?(quote)

      buf, pos = quoted_literal(text, pos + 1, quote)
      parts << buf
    end
    parts.empty? ? nil : parts.join
  end

  # The content of one literal whose opening `quote` sits just before `pos`, and
  # the offset past its closing quote. A single-quoted literal unescapes only
  # `\\` and `\'`.
  def quoted_literal(text, pos, quote)
    buf = +''
    while pos < text.length
      return [buf, pos + 1] if text[pos] == quote

      step = escape?(text, pos, quote) ? 1 : 0
      buf << text[pos + step]
      pos += step + 1
    end
    [buf, pos]
  end

  def escape?(text, pos, quote)
    text[pos] == '\\' && (quote == '"' || ['\\', "'"].include?(text[pos + 1]))
  end

  # The body of the first `key: { … }` at or after `from`, brace-balanced and
  # string-aware, and the offset just past the closing brace. A caller can keep
  # scanning from there; an empty body ("properties: {}") still advances.
  def brace_body_at(text, key, from = 0)
    match = text.match(/(?<![a-z_])#{key}:\s*\{/, from)
    return nil unless match

    stop = closing_offset(text, match.end(0))
    [text[match.end(0)...(stop - 1)], stop]
  end

  # The offset just past the bracket that closes the one opened before `start`.
  def closing_offset(text, start)
    scanner = StringScanner.new(text)
    scanner.pos = text[0, start].bytesize
    depth = 1
    depth += BRACKETS.fetch(scanner.scan(/#{STRING}|./mo), 0) until scanner.eos? || depth.zero?
    scanner.charpos
  end

  # `key:` symbol keys at brace and bracket depth 0 of a hash body. A quoted
  # literal is skipped. Remove comments from the body first.
  def top_level_keys(body)
    return [] if body.nil?

    keys = []
    depth = 0
    scanner = StringScanner.new(body)
    depth = scan_key_token(scanner, depth, keys) until scanner.eos?
    keys
  end

  # Consumes one token: a literal, a bracket, a key at depth 0, or one
  # character. Adds a found key to `keys` and returns the new depth.
  def scan_key_token(scanner, depth, keys)
    token = scanner.scan(/#{STRING}|[{}\[\]]/o)
    return depth + BRACKETS.fetch(token, 0) if token

    if depth.zero? && key_start?(scanner.string, scanner.charpos) && scanner.scan(KEY)
      keys << scanner[1]
    else
      scanner.getch
    end
    depth
  end

  def key_start?(body, pos)
    pos.zero? || !body[pos - 1].match?(/[A-Za-z0-9_:]/)
  end
end
