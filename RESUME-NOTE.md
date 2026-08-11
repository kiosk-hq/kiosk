# RESUME-NOTE — T-053 (K-495 slice 2 of 6): the mixin + macros

Branch `mixin-0811`, worktree `reference.mixin-0811`. Owner of
`kiosk-server/lib/**` + `kiosk-server/spec/**` ONLY. Delete this file in the
final commit.

## What T-053 is

Ship `Kiosk::Query` / `Kiosk::Action` as **modules an operator includes** into a
controller THEY own. Phil: "не наследуем. Наследование решает оператор. Мы
только представляем миксин и его include." K-496 is answered: keep the
run/action dualism, NO rename, NO wire change.

## Design decisions taken (and why)

1. **Two public modules, one internal implementation.** `Kiosk::Action` and
   `Kiosk::Query` are 5-line shims over `Kiosk::Server::HandlerMixin.install`.
   Two, not one, because the KIND (which registry) must be declared, and the
   `include` line is the natural place. Including both into one class raises.
2. **The mixin registers into the EXISTING registries** via the existing public
   `Actions.register(name, callable, description:, …)`. The stored callable is a
   `HandlerDispatch`. Zero changes to the registries' semantics ⇒ the 7 demos'
   `register` blocks keep working untouched (T-057 migrates them).
3. **Dispatch is the router's own mechanism** — `Controller.action(m).call(env)`
   (T-053/K-495), double-gated: the wire name is looked up in a registry built
   at class-definition time (so a wire name can only ever reach a DECLARED
   method), and `action_methods.include?(m)` is re-checked at dispatch.
4. **The sub-request env is FRESH, seeded from the outer one** (HTTP_* headers,
   REMOTE_ADDR, SERVER_*, rack.url_scheme, rack.session, request_id). NOT
   `request.env.dup`: the outer env carries a consumed `rack.input` and memoised
   `action_dispatch.request.parameters`, which would leak into the sub-request.
   Params are injected via `action_dispatch.request.request_parameters`, which
   `ActionDispatch::Http::Parameters#POST` short-circuits on — so no re-encode.
5. **Identity reaches the handler as `env["kiosk.identity"]`**, carried from
   WireController through `Kiosk::Server::CurrentRequest` (block-scoped
   thread-local, not CurrentAttributes: no reliance on the Rails executor
   resetting it). `kiosk_identity` is the handler-side reader.
6. **`env["kiosk.dispatch"]` is the anti-footgun.** A `before_action` 404s any
   request that did NOT come through the Kiosk seam, so an operator who also
   ROUTES the handler controller does not thereby expose an unauthenticated,
   CSRF-exempt endpoint.
7. **`skip_forgery_protection` on include** (when the base responds to it). The
   wire request is authenticated by bearer/PoP at WireController, never by a
   cookie session, and a server-internal sub-dispatch can never carry a CSRF
   token. Without it every real app (`default_protect_from_forgery`) would 500.
8. **Non-2xx renders map to wire errors** (400/401/403/404/409/422/429). This is
   deliberately THIN and marked as T-054's to own/replace; a handler needing a
   code HTTP status cannot carry still just `raise Kiosk::Server::Errors::X`,
   which propagates unchanged.
9. **Pagination stays expressible**: `render_kiosk_page(rows, next_cursor:)`
   marks `env["kiosk.page"]` and the dispatcher rebuilds a `Server::Page`, so a
   paginating query (hoteling) is migratable in T-057.
10. **Reload safety**: the dispatcher stores the controller's NAME (String) and
    constantizes per call, so Zeitwerk reloading in dev picks up handler edits
    without a restart — K-495 charge (2).

## Known limit, documented not hidden

A handler controller that Rails has not loaded yet is not in the registry, so
`GET /kiosk/schema` under `eager_load = false` (dev) can under-report until the
class is first referenced. Production eager-loads `app/controllers`. Documented
in the README; filed as a K-candidate in the final report.

## K-candidates found (report only — scope rule)

- minor / D7 — four demos ship NO `app/controllers/application_controller.rb`
  (getgrocery, hoteling, prove, skooti); their controllers inherit
  `ActionController::Base` / `::API` directly, e.g.
  `kiosk-demo-getgrocery/app/controllers/home_controller.rb:1`. T-057's
  migration and T-056's generator both assume a host base class exists.

## Status

- [x] registries gain `output_schema:` (ADR-0023 / K-500), additive
- [x] `lib/kiosk/server/current_request.rb`, `handler_dispatch.rb`,
      `handler_mixin.rb`, `lib/kiosk/action.rb`, `lib/kiosk/query.rb`
- [x] WireController + TestExecutor carry the identity
- [x] specs: `spec/kiosk/server/handler_mixin_spec.rb` (consumer-level, real
      executor path) + `handler_dispatch_spec.rb`
- [x] README seam section + CHANGELOG line
