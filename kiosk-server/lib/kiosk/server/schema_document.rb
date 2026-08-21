# frozen_string_literal: true

require "digest"
require "json"
require "kiosk/server/actions"
require "kiosk/server/queries"
require "kiosk/server/schema_slots"
require "kiosk/server/version"

module Kiosk
  module Server
    # THE `schema` CATALOG, DERIVED ONCE PER BOOT AND SERVED FROM MEMORY
    # (T-094, Phil 2026-08-19).
    #
    # `GET <endpoint>/schema` answers `{queries, actions}` — the descriptors of
    # every verb this origin registered. Nothing in it is per-request or
    # per-agent, which is why it is PUBLIC and cacheable at all, and why the
    # same bytes can be handed to every caller for as long as the process
    # lives.
    #
    # ── Why this is derived, not pre-generated ─────────────────────────────
    #
    # The rejected alternative was emitting a static file at deploy time. It
    # was refused for one concrete reason: the verb roster is not the only
    # input. **A `kiosk-server` PATCH bump can change the bytes too** — the
    # renderer is in this gem — so a digest taken over the registry alone
    # would LIE the first time the gem moved under an unchanged catalog.
    # {digest_inputs} therefore covers all three: the registry, the origin's
    # config, and the gem/protocol version. And because the document is
    # derived by the SAME PROCESS that serves it, there is no second artefact
    # for it to drift from: drift is impossible by construction rather than
    # caught by a guard.
    #
    # ── When it is derived ─────────────────────────────────────────────────
    #
    # {Engine} derives it in `config.after_initialize` — after eager loading,
    # so a production host whose handlers register by being read is fully
    # registered — and {Engine}'s `config.to_prepare` calls {reset!} right
    # after it rebuilds the registry, so a development reload re-derives.
    # {derived?} is what a boot check asks: "was this computed at boot, or is
    # some request about to pay for it?"
    #
    # The memo is keyed ({cache_key}) on the config object plus the registered
    # names, so a spec that declares a verb after a first read is not served a
    # stale catalogue. That check is three array reads; the DERIVATION — build
    # every descriptor, serialize, hash — is what happens once.
    #
    # ── "Once per boot" HAS AN EXCEPTION SINCE K-922, and it is the point ───
    #
    # A descriptor slot may be a PROC — `enum: -> { Category.pluck(:slug) }` —
    # which makes the catalogue a function of the operator's ROWS, not only of
    # their code. Phil's constraint is that such a change «должен обновляться
    # динамически, без деплоя»: adding a category must publish itself without
    # a restart. A memo keyed on the verb NAMES cannot see that change — the
    # names did not move — so {cache_key} carries {SchemaSlots.epoch} too, and
    # this document re-derives once per refresh window while any slot is
    # dynamic. On an origin with no proc anywhere the epoch is a constant `0`
    # and nothing about the boot-derived memo changes.
    #
    # THE DERIVATION IS SYNCHRONISED, for the same reason {SchemaSlots} is: a
    # dynamic slot means the derivation runs a QUERY, and Puma is
    # multi-threaded, so an unlocked double-check would run it once per racing
    # thread. {MUTEX} is taken AFTER {SchemaSlots::MUTEX} is never taken —
    # this module locks first and calls into that one, never the reverse — so
    # the two cannot deadlock.
    #
    # ── The digest is a cache-busting version, not a secret ────────────────
    #
    # It travels two ways: as the strong `ETag` of the response, and as the
    # `?v=` on the URL the discovery documents link ({WellKnown}). The second
    # is what makes a year-long TTL safe — see {Headers} for the two cache
    # policies and why a fixed URL cannot carry the long one.
    #
    # SINCE K-804 IT IS THE ORIGIN'S DOCUMENT VERSION, not this document's.
    # `GET <endpoint>/openapi.json` went public in the same shape, and the
    # api-catalog hangs THIS value on the `?v=` of both links, because
    # {digest_inputs} covers every input of either renderer. The two documents
    # keep their own `ETag`s — an entity tag identifies bytes at one url — but
    # they share one version, and a deploy that moves either moves it.
    module SchemaDocument
      # Hex characters of SHA-256 kept. 128 bits: collision-free for a
      # cache-busting version, and short enough to read in a URL.
      DIGEST_LENGTH = 32

      # Guards {derive} and {derive!}. See the header note.
      MUTEX = Mutex.new

      class << self
        # The catalog document, ready to serialize: `{queries:, actions:}`.
        #
        # `verbs` is NOT here (T-095, K-801). It rendered
        # `Array(Kiosk.configuration.capabilities)` — literally the same call
        # `/.well-known/kiosk.json` renders as `capabilities`, so it was one
        # value published twice under two names. The module set lives in the
        # discovery document, which is the same trust state as this one now
        # that both are public.
        def document(config: Kiosk.configuration)
          derive(config: config).fetch(:document)
        end

        # The document as the JSON bytes the wire writes — serialized once,
        # with the digest, so serving it is a string write.
        def json(config: Kiosk.configuration)
          derive(config: config).fetch(:json)
        end

        # Lowercase hex, {DIGEST_LENGTH} characters. Changes when any of
        # {digest_inputs} changes.
        def digest(config: Kiosk.configuration)
          derive(config: config).fetch(:digest)
        end

        # The strong HTTP entity tag: the digest, quoted. Strong (no `W/`)
        # because the bytes are byte-identical for every caller — there is no
        # negotiated variant for a weak tag to stand for.
        def etag(config: Kiosk.configuration)
          %("#{digest(config: config)}")
        end

        # True when the document is already in memory. A boot check asserts
        # this WITHOUT calling {digest} first — that is the whole difference
        # between "derived at boot" and "derived by whoever asked first".
        def derived?
          !@memo.nil?
        end

        # Derive now, discarding any memo. {Engine} calls this at
        # `after_initialize`; a host that builds its registry by some other
        # route may call it too.
        #
        # A DYNAMIC SLOT MAY NOT BE RESOLVABLE YET, and that is not an error
        # here (K-922). `after_initialize` runs on EVERY boot — `db:create`,
        # `db:migrate` and `assets:precompile` included — and a slot declared
        # `enum: -> { Category.pluck(:slug) }` has no table to read at the
        # first two. Deriving eagerly is an optimisation, so when it fails on
        # an origin that has a proc somewhere, the memo is simply left empty
        # and the first request pays for it (and raises there, in front of a
        # caller, if the database is genuinely broken). An origin with NO proc
        # anywhere cannot hit this: nothing in its derivation touches the
        # database, so a raise is a real defect and is re-raised.
        def derive!(config: Kiosk.configuration)
          MUTEX.synchronize { @memo = build(config) }
          self
        rescue StandardError => error
          raise unless SchemaSlots.dynamic_declarations?

          @memo = nil
          deferred_derivation_warning(error)
          self
        end

        # Drop the memo. {Engine} calls this from `to_prepare`, right after
        # the registry is rebuilt.
        def reset!
          @memo = nil
          self
        end

        private

        # Memo hit when the config object and the registered names are
        # unchanged; otherwise derive. A code reload changes descriptors
        # without changing names — that case is covered by {reset!} from
        # `to_prepare`, which is the only way a descriptor changes in a
        # running process.
        def derive(config:)
          key  = cache_key(config)
          memo = @memo
          return memo if memo && memo[:key] == key

          MUTEX.synchronize do
            # RE-READ INSIDE THE LOCK, key included: the epoch may have rolled
            # while this thread was waiting, and the thread that held the lock
            # may already have built exactly what this one wants.
            key  = cache_key(config)
            memo = @memo
            next memo if memo && memo[:key] == key

            @memo = build(config, key: key)
          end
        end

        def build(config, key: nil)
          document = { queries: Queries.catalog, actions: Actions.catalog }.freeze
          inputs   = digest_inputs(config, document)
          digest   = Digest::SHA256.hexdigest(JSON.generate(inputs))[0, DIGEST_LENGTH]

          { key: key || cache_key(config), document: document,
            json: JSON.generate(document).freeze, digest: digest.freeze }.freeze
        end

        # `SchemaSlots.epoch` is the ONLY member that can move without a code
        # change, and it is a constant `0` unless some declaration carries a
        # proc — see the header note.
        def cache_key(config)
          [config.object_id, Queries.known.sort, Actions.known.sort,
           Array(config.capabilities), SchemaSlots.epoch]
        end

        def deferred_derivation_warning(error)
          message =
            "[kiosk-server] the schema catalog could not be derived at boot " \
            "(#{error.class}: #{error.message}). A descriptor slot on this origin is " \
            "data-derived (a proc), and the data was not reachable — normal during " \
            "db:create, db:migrate and assets:precompile. It will be derived on first read."
          logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
          logger ? logger.info(message) : warn(message)
        end

        # EVERYTHING THAT CAN CHANGE THE BYTES A CLIENT WOULD CACHE, and
        # nothing that cannot. Three groups, and all three are required:
        #
        #   * the REGISTRY — the document itself, so a verb added, renamed,
        #     re-described or re-schema'd moves the digest;
        #   * the ORIGIN CONFIG — the fields the discovery documents publish
        #     beside the catalog, so a re-issued skill pin or a moved mount
        #     invalidates the linked URL too;
        #   * the VERSIONS — `kiosk-server`'s own, because the renderer lives
        #     in this gem and a PATCH bump can change what it emits, and the
        #     protocol's, for the same reason one level up.
        #
        # `owner` IS ONE OF THEM, and it joined at K-804 rather than at T-094.
        # This digest stopped being the catalog's alone the day the api-catalog
        # began hanging it on the `?v=` of BOTH derived documents: {OpenApi}
        # renders `info.title` from `WellKnown.site_name`, which reads
        # `owner[:name]`. Leaving it out would have let an operator rename
        # itself, publish an unchanged version, and have a year-long cache
        # keep serving the old title. It is a cheap read and it makes the one
        # sentence this constant depends on — "every input of either document
        # is an input here" — true rather than nearly true.
        def digest_inputs(config, document)
          {
            gem_version:      Kiosk::Server::VERSION,
            protocol_version: Kiosk::Protocol::API_VERSION,
            issuer:           config.issuer.to_s,
            mount_path:       config.mount_path.to_s,
            capabilities:     Array(config.capabilities),
            min_client:       config.min_client.to_s,
            owner:            config.owner,
            skill:            [config.skill_url.to_s, config.skill_sha256.to_s],
            document:         document,
          }
        end
      end
    end
  end
end
