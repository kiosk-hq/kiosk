# frozen_string_literal: true

require "digest"
require "json"
require "kiosk/server/actions"
require "kiosk/server/queries"
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
    # ── The digest is a cache-busting version, not a secret ────────────────
    #
    # It travels two ways: as the strong `ETag` of the response, and as the
    # `?v=` on the URL the discovery documents link ({WellKnown}). The second
    # is what makes a week-long TTL safe — see {Headers} for the two cache
    # policies and why a fixed URL cannot carry the long one.
    module SchemaDocument
      # Hex characters of SHA-256 kept. 128 bits: collision-free for a
      # cache-busting version, and short enough to read in a URL.
      DIGEST_LENGTH = 32

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
        def derive!(config: Kiosk.configuration)
          @memo = build(config)
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
          key = cache_key(config)
          return @memo if @memo && @memo[:key] == key

          @memo = build(config, key: key)
        end

        def build(config, key: nil)
          document = { queries: Queries.catalog, actions: Actions.catalog }.freeze
          inputs   = digest_inputs(config, document)
          digest   = Digest::SHA256.hexdigest(JSON.generate(inputs))[0, DIGEST_LENGTH]

          { key: key || cache_key(config), document: document,
            json: JSON.generate(document).freeze, digest: digest.freeze }.freeze
        end

        def cache_key(config)
          [config.object_id, Queries.known.sort, Actions.known.sort, Array(config.capabilities)]
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
        def digest_inputs(config, document)
          {
            gem_version:      Kiosk::Server::VERSION,
            protocol_version: Kiosk::Protocol::API_VERSION,
            issuer:           config.issuer.to_s,
            mount_path:       config.mount_path.to_s,
            capabilities:     Array(config.capabilities),
            min_client:       config.min_client.to_s,
            skill:            [config.skill_url.to_s, config.skill_sha256.to_s],
            document:         document,
          }
        end
      end
    end
  end
end
