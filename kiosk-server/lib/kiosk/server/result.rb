# frozen_string_literal: true

module Kiosk
  module Server
    # A paginated slice of query rows. A `query` handler that returns a large
    # list opts into cursor pagination by returning one of these instead of a
    # bare Array.
    #
    #   rows        — the (truncated) Array<Hash> for THIS page.
    #   next_cursor — an OPAQUE String the assistant echoes back in the next
    #                 request's `cursor` param to fetch the following page.
    #                 PRESENT (non-nil) means the result was truncated (more
    #                 rows exist); nil/absent means this is the last page.
    #   total       — OPTIONAL: how many rows MATCH the query across all pages,
    #                 not how many this page carries. It becomes
    #                 `X-Total-Count`. nil means "this handler does not know",
    #                 and nil is the honest answer for a keyset cursor over a
    #                 set nobody counted — the header is then omitted rather
    #                 than filled with the page size, which would be a lie.
    #
    # The cursor is opaque BY CONTRACT: the assistant never parses it, it only
    # round-trips it. A handler is free to encode an offset, a keyset token, or
    # anything else behind it. {Cursor} provides a decimal offset helper for
    # the common case — the token it emits is the integer in clear, and the
    # opacity is the client's contract, not a property of the string; a handler
    # MAY use its own scheme.
    #
    # NEITHER FIELD REACHES THE BODY. The rows ARE the body — a bare JSON
    # array, the same shape every other query answers — and the two facts about
    # the page travel as RESPONSE HEADERS: `Link: <…>; rel="next"` (RFC 8288)
    # and `X-Total-Count`. See {WireController#add_pagination_headers}.
    #
    # Pagination applies to LIST results only. Single-object/action/pay results
    # (kind: :value) never carry a cursor.
    Page = Data.define(:rows, :next_cursor, :total) do
      def initialize(rows:, next_cursor: nil, total: nil)
        super(rows: rows, next_cursor: next_cursor, total: total)
      end

      # True when the result was truncated (more rows exist beyond this page).
      #
      # NO CALLER IN THIS REPOSITORY, and it ships anyway: {Page} is the type an
      # OPERATOR's query handler returns, so this is the readable spelling of
      # the `next_cursor` contract for the code that BUILDS a page, not for the
      # wire — the wire reads `next_cursor` itself, in
      # {WireController#add_pagination_headers}. `page_spec.rb` holds both
      # answers.
      def truncated? = !next_cursor.nil?
    end

    # Cursor helper for the common offset-pagination case. A handler MAY ignore
    # this and roll its own token — the wire contract only requires that whatever
    # the handler emits as `next_cursor` be echoed back verbatim in the next
    # request's `cursor` param.
    #
    #   Cursor.encode_offset(40)              # => "40"
    #   Cursor.decode_offset("40", default: 0) # => 40
    #
    # THE OFFSET IS PUBLISHED AS A DECIMAL INTEGER, IN CLEAR, AND THIS PARAGRAPH
    # IS THE «SAY SO» HALF OF THAT. Wrapping `offset:N` in urlsafe base64 would
    # be a costume: not a secret, not signed, not stable across a collection
    # that changes under the reader, and decodable by anyone in one line. It
    # would tell a reader «opaque, do not parse» while providing not one of the
    # properties opacity is FOR, which is worse than saying nothing — a reader
    # who believes the token is protected reasons about it wrongly. So it says
    # what it is.
    #
    # OPACITY IS STILL THE CONTRACT, AND THE CONTRACT IS ON THE CLIENT, NOT ON
    # THE TOKEN. The specification requires an assistant never to parse a cursor
    # and never to construct one; it requires nothing of the token's shape,
    # because the shape is the operator's to choose and to change. Publishing an
    # integer does not weaken that rule — an assistant that starts doing
    # arithmetic on this value is out of contract the day the handler switches to
    # a keyset token.
    #
    # NOTHING IS AUTHORIZED BY A CURSOR, and that is why this needs no signature.
    # A forged `cursor=5000` reaches exactly the rows the same request would have
    # reached by following five thousand links: the handler's own scoping decides
    # what a page may contain, and a cursor only says how far in. A handler that
    # would leak on a forged offset is a handler with no scoping, and an HMAC
    # would hide that rather than fix it.
    #
    # AND THE DECODE IS NOT LENIENT. An ABSENT cursor is `default`, because
    # absence legitimately means «first page»; anything PRESENT that is not a
    # non-negative decimal integer is a typed 400 naming the parameter, which
    # is what every other bad argument on this wire gets and what the spec
    # requires — silently serving page one «reads to an AI assistant as a valid
    # answer to a request it did not make».
    #
    # AN OFFSET CURSOR IS INDEPENDENT OF WHERE THE CURSOR TRAVELS, which is
    # why this helper is unaffected by the two page facts being headers. The
    # wire has `limit`/`cursor` as reserved request parameters, and a truncated
    # page hands back a token the client round-trips — inside a `Link` header's
    # target URI, not a body field — so a handler paginating by offset needs
    # exactly this helper and nothing more.
    module Cursor
      # A cursor this helper wrote: one or more decimal digits, nothing else.
      OFFSET_RE = /\A[0-9]+\z/

      module_function

      def encode_offset(offset)
        offset.to_i.to_s
      end

      # @param cursor [String, nil] the `cursor` request parameter, verbatim
      # @param default [Integer] the offset an ABSENT cursor means
      # @raise [Errors::BadRequest] when a cursor is present and is not one this
      #   helper could have written
      def decode_offset(cursor, default: 0)
        return default if cursor.nil? || cursor.to_s.empty?

        raw = cursor.to_s
        unless raw.match?(OFFSET_RE)
          raise Errors::BadRequest.new(
            "cursor #{raw.inspect} is not a cursor this endpoint issued",
            hint: "do not build a cursor: fetch the `Link: <…>; rel=\"next\"` target verbatim, " \
                  "or copy its `cursor` parameter byte for byte. Omit `cursor` for the first page.",
          )
        end

        Integer(raw, 10)
      end
    end

    # The {Executor}'s internal carrier for a successful call, serialised by
    # {WireController#render_result}. Errors travel as {Errors::Base#to_problem}.
    #
    # It is INTERNAL, and that is the whole of what it is: nothing it holds
    # reaches the wire as a field. `kind` distinguishes
    # the payload shape for the Executor's own bookkeeping —
    #
    #   :rows   — a query's rows (Array<Hash>, or whatever the handler rendered)
    #   :value  — a single value returned by an Action or by `pay`
    #
    # — and `next_cursor`/`total` are OPTIONAL, only ever set on a :rows Result
    # whose query handler paginated (returned a {Page}). They do not become
    # body fields: {#to_payload} is the payload and nothing else, and the two
    # page facts are written as RESPONSE HEADERS by the wire controller.
    #
    # Those two kinds are the whole set: `KINDS` below is what {#initialize}
    # accepts and anything else raises.
    Result = Data.define(:kind, :payload, :next_cursor, :total) do
      KINDS = %i[rows value].freeze

      def initialize(kind:, payload:, next_cursor: nil, total: nil)
        kind = kind.to_sym
        unless KINDS.include?(kind)
          raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}"
        end
        if next_cursor && kind != :rows
          raise ArgumentError, "next_cursor is only valid on a :rows result (got #{kind.inspect})"
        end
        if total && kind != :rows
          raise ArgumentError, "total is only valid on a :rows result (got #{kind.inspect})"
        end

        super(kind: kind, payload: payload, next_cursor: next_cursor, total: total)
      end

      # A Result IS the success case — a refusal never becomes one, errors
      # travel as {Errors::Base#to_problem} — so 200 is not a default here, it
      # is the only status this type has.
      def http_status = 200

      # THE SUCCESS BODY: the handler's rendered payload, VERBATIM. No `ok`,
      # no `kind`, no wrapper, and no composite case either — the status line
      # already says "success" and `output_schema` says what the shape is.
      #
      # A PAGINATING QUERY ANSWERS THE SAME BARE ARRAY AS EVERY OTHER QUERY.
      # There is exactly ONE query body shape on this wire, because the
      # transport metadata a page needs lives where HTTP already keeps it —
      # RFC 8288 (Web Linking), the `Link` response header, `rel="next"`. DO
      # NOT wrap a page in a body of its own (spec §8.2/§8.4).
      def to_payload = payload
    end
  end
end
