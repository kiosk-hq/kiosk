# frozen_string_literal: true

module Kiosk
  module Server
    # DATA-DERIVED DESCRIPTOR SLOTS — a `Proc` in a declaration, resolved
    # LAZILY, memoized, and refreshed WITHOUT A RESTART (K-922, Phil
    # 2026-08-21).
    #
    #   input_schema type: "object", additionalProperties: false,
    #                properties: {
    #                  category_slug: { type: "string",
    #                                   enum: -> { Category.pluck(:slug) } },
    #                }
    #
    # ── Why a proc rather than the obvious call ────────────────────────────
    #
    # `enum: Category.pluck(:slug)` in a class body runs at CLASS LOAD, which
    # is `db:create`, `db:migrate` and `assets:precompile` as well as a serving
    # boot — there is no table (or no database) at some of those, and the value
    # it captures is then frozen for the life of the process anyway. A proc
    # defers BOTH problems: nothing is called while the class body is read, and
    # what is called is called again later.
    #
    # ── Two things Phil asked for, and they pull against each other ────────
    #
    #   (1) «Можно закешировать при первом вызове» — resolve once and reuse.
    #       Necessary: {Queries.describe} is on the PER-REQUEST validation path
    #       (see {VerbController#arguments_for}), so an unmemoized proc is a
    #       database round-trip added to every verb call.
    #   (2) «каталог должен обновляться динамически, без деплоя» — an operator
    #       who adds a category must not have to restart or redeploy to
    #       publish it.
    #
    # A memo that lives forever satisfies (1) and BREAKS (2): the served schema
    # would then change only when the process does, which is the deploy
    # dependency the decision exists to remove. So the memo has a LIFETIME:
    # it is cached on first call and re-resolved once {refresh_seconds} have
    # passed. {REFRESH_SECONDS} is 60 to match {Headers::SHORT_MAX_AGE} — the
    # freshness lifetime of `/.well-known/kiosk.json`, the pointer document a
    # client re-reads to find the catalog. A schema that refreshed faster than
    # its own pointer could not be OBSERVED as fresher; one that refreshed
    # slower would make the pointer's minute a lie.
    #
    # ── The race, and why a Mutex ──────────────────────────────────────────
    #
    # The demos ship `WEB_CONCURRENCY=1`, but Puma is MULTI-THREADED, so two
    # requests filling an empty (or just-expired) memo at the same instant is
    # an ordinary event, not a corner case. Unsynchronised, `@cache[key] ||=
    # resolve(...)` runs the proc once per racing thread — N database queries
    # for one value — and, worse, the threads can publish DIFFERENT values if
    # the underlying rows changed between them, so one caller's descriptor and
    # another's disagree inside one epoch.
    #
    # ONE MUTEX, DOUBLE-CHECKED, WITH A COPY-ON-WRITE CACHE:
    #
    #   * the fast path reads `@cache` WITHOUT the lock. That is safe because
    #     the cache is never mutated in place: a miss builds a whole new Hash,
    #     freezes it and REPLACES the ivar, so a reader sees either the old
    #     complete Hash or the new complete Hash and never a half-written one.
    #     In-place `Hash#[]=` would not be safe on a truly parallel runtime
    #     (JRuby, TruffleRuby), and this gem is not entitled to assume the GVL.
    #   * the slow path takes the lock, RE-CHECKS, and only then calls the
    #     proc. So the proc runs exactly once per key per epoch and every
    #     racing thread is handed the SAME resolved object.
    #
    # REJECTED ALTERNATIVES, recorded because each is the obvious next idea:
    #   * `Concurrent::Map#compute_if_absent` — single-execution is an MRI
    #     guarantee, not a documented cross-runtime one, and it has no
    #     expiry, so (2) would still need building on top.
    #   * per-key mutexes — the critical section is one cheap query per key
    #     per minute; a lock table is more moving parts than the contention
    #     justifies.
    #   * no memo, resolve per request — correct and always fresh, but it puts
    #     a query on the hot path of every verb call, which is (1).
    #   * idempotent recompute with no lock — leaves the "two threads, two
    #     different answers inside one epoch" half of the race unfixed.
    #
    # ── Nothing changes for an origin with no proc anywhere ────────────────
    #
    # {dynamic?} is a STRUCTURAL walk — it looks for `Proc` objects and never
    # calls one — run once per declaration at class-body load. Until it finds
    # one, {epoch} is a constant `0` and {descriptor} yields straight through
    # with no cache, no walk and no clock read. So the six demos that declare
    # only literal enums behave exactly as they did before this file existed:
    # the catalog is derived once at boot and never again.
    module SchemaSlots
      # The declaration slots a proc may appear in, at any depth.
      #
      # These four are STRUCTURE — schemas and the examples that illustrate
      # them — and every part of them can legitimately be a fact about the
      # operator's data: an `enum` of categories, a `maximum` read from a
      # configured cap, an `example_row` built from a real row. Restricting
      # this to `enum` would have been an arbitrary carve-out that needed an
      # engine change the first time someone wanted `default:`.
      #
      # `description`, `kind` and `wire_name` are deliberately NOT here.
      # `kind` and `wire_name` are ROUTING facts, fixed when the route is
      # drawn — a proc there would promise a path that can change under a
      # running process, and it cannot. `description` is prose semantics
      # (ADR-0023): what a verb MEANS does not vary with a row.
      RESOLVABLE_SLOTS = %i[input_schema output_schema example_params example_row].freeze

      # How long a resolved value is reused before it is re-resolved. Matches
      # {Headers::SHORT_MAX_AGE}; see the note above for why.
      REFRESH_SECONDS = 60

      # Guard against a proc that returns a proc that returns a proc… A
      # declaration is a handful of levels deep; anything past this is a loop.
      MAX_DEPTH = 32

      MUTEX = Mutex.new

      class << self
        # Seconds a resolved value is reused. Settable — a test, or an
        # operator with a slower-moving vocabulary, may tune it. `0` (or less)
        # means "no memo": re-resolve on every read.
        def refresh_seconds
          defined?(@refresh_seconds) && !@refresh_seconds.nil? ? @refresh_seconds : REFRESH_SECONDS
        end

        attr_writer :refresh_seconds

        # Does this value tree contain a proc ANYWHERE? Structural only: it
        # inspects, it never calls. Safe to run at class-body load, which is
        # where {Queries.declare} runs it.
        def dynamic?(value, depth = 0)
          return false if depth > MAX_DEPTH

          case value
          when Proc  then true
          when Hash  then value.any? { |_key, member| dynamic?(member, depth + 1) }
          when Array then value.any? { |member| dynamic?(member, depth + 1) }
          else false
          end
        end

        # Record that a declaration carried a proc. Called once per declared
        # verb, from the registries. Latching: once an origin has one dynamic
        # declaration it takes the resolving path for all of them, which costs
        # one memoized walk per verb per epoch and saves a per-declaration
        # bookkeeping table.
        def note_declaration(slots)
          return true if dynamic_declarations?

          @dynamic = RESOLVABLE_SLOTS.any? { |slot| dynamic?(slots[slot]) }
        end

        # True once any declaration on this origin has carried a proc.
        def dynamic_declarations?
          defined?(@dynamic) ? !!@dynamic : false
        end

        # The current memo generation. Constant `0` while no declaration is
        # dynamic — that is what keeps {SchemaDocument}'s boot-derived memo
        # boot-derived for a static origin. It is a MONOTONIC clock: this is a
        # cache lifetime, so it must not move when the wall clock is stepped.
        def epoch
          return 0 unless dynamic_declarations?

          seconds = refresh_seconds.to_f
          now     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return now if seconds <= 0

          (now / seconds).floor
        end

        # The resolved descriptor for one verb. `entry` is the registry Entry
        # the descriptor was built from — identity, not equality, so a
        # re-declaration (a code reload, {HandlerRegistrations.reload!})
        # invalidates without anybody having to remember to.
        #
        # The block builds the RAW descriptor and is called only on a miss.
        def descriptor(scope, name, entry)
          return yield unless dynamic_declarations?

          key       = [scope, name.to_s].freeze
          now_epoch = epoch
          hit       = cache[key]
          return hit[:value] if fresh?(hit, entry, now_epoch)

          MUTEX.synchronize do
            hit = cache[key]
            return hit[:value] if fresh?(hit, entry, now_epoch)

            value = resolve(yield).freeze
            @cache = cache.merge(
              key => { value: value, entry: entry, epoch: now_epoch }.freeze,
            ).freeze
            value
          end
        end

        # Deep-resolve a value: every proc is called, and its result is
        # resolved in turn. Containers that held no proc are returned as they
        # were, so an all-literal schema is not needlessly copied.
        def resolve(value, depth = 0)
          raise ArgumentError, "kiosk: descriptor slot nests procs more than #{MAX_DEPTH} deep" if depth > MAX_DEPTH

          case value
          when Proc  then resolve(value.call, depth + 1)
          when Hash  then dynamic?(value) ? value.transform_values { |m| resolve(m, depth + 1) } : value
          when Array then dynamic?(value) ? value.map { |m| resolve(m, depth + 1) } : value
          else value
          end
        end

        # Drop every resolved value and the dynamic latch. The engine calls
        # this from `to_prepare`, BEFORE the registry is rebuilt — a code
        # reload may have removed the only proc on the origin.
        def reset!
          MUTEX.synchronize do
            @cache   = {}.freeze
            @dynamic = false
          end
          self
        end

        private

        def fresh?(hit, entry, now_epoch)
          !hit.nil? && hit[:epoch] == now_epoch && hit[:entry].equal?(entry)
        end

        def cache
          @cache ||= {}.freeze
        end
      end
    end
  end
end
