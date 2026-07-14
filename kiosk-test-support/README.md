# kiosk-test-support

Framework-agnostic journey-test DSL for the [Kiosk](https://kiosk.tech) test harnesses.

## What it does

Carries the shared pieces of the Kiosk journey-test DSL: the `Journey` module mixed into RSpec / Minitest tests, the pluggable `executor` contract, a `NullExecutor` for self-tests, and the structured error classes that the framework-specific matchers and assertions look for.

You normally don't install this gem directly — install one of the harnesses:

```ruby
group :test do
  gem "kiosk-rls-rspec"       # RSpec
  # or
  gem "kiosk-rls-minitest"    # Minitest
end
```

Both harnesses pull `kiosk-test-support` as a transitive dependency.

## DSL

```ruby
as_agent_of(alice) do
  run_action :create_order, items: ["bread"]
end

as_user(alice) do
  expect(query("select item from orders")).to contain_exactly("bread")
end

as_anonymous do
  expect { query("select * from orders") }.to be_rls_denied
end
```

Helpers: `as_agent_of(user, role:)`, `as_user(user, role:)`, `as_agent(name)`, `as_anonymous`, `query(sql)`, `run_action(name, **args)`, `pay_action(name, **args)`, `kiosk_seed(table, count:, owner:, **attrs)`. See the `Kiosk::TestHelpers::Journey` docstrings for full semantics.

## Wiring an executor

The DSL is inert until you wire an executor. In production-shaped tests you wire `Kiosk::Server::TestExecutor` (ships with `kiosk-server`):

```ruby
# spec/spec_helper.rb (RSpec) or test/test_helper.rb (Minitest)
require "kiosk/server/test_executor"
Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new
```

For unit-shaped tests where you only care about call ordering, use the bundled `NullExecutor`:

```ruby
Kiosk::TestHelpers.executor = Kiosk::TestHelpers::NullExecutor.new.tap do |e|
  e.enqueue_query [{ "item" => "bread" }]
end
```

The `NullExecutor` is the zero-dependency fallback for unit-shaped tests; production-shaped tests wire `Kiosk::Server::TestExecutor` from the shipped `kiosk-server` gem (above).

## Status

Pre-v1.0 alpha. The Journey DSL surface is stable across pre-v1.0 minor bumps; the executor contract may still evolve pre-v1.0 (`kiosk-server` ships `Kiosk::Server::TestExecutor` against it today).

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
