# kiosk-rls-minitest

Minitest integration for the [Kiosk](https://kiosk.tech) journey-test DSL.

## What it does

Wires the framework-agnostic journey-test DSL (`kiosk-test-support`) into Minitest. Adds:

- A convenience include — `include Kiosk::TestHelpers` mixes the journey helpers (`as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`, `run_action`, `pay_action`, `kiosk_seed`) and the assertions into a `Minitest::Test` subclass.
- Assertions: `assert_rls_denied { block }`, `assert_quota_exceeded { block }`, plus `refute_*` negative forms.
- Spec-DSL: `proc { ... }.must_raise_rls_denied`, etc.

## Install

```ruby
group :test do
  gem "kiosk-rls-minitest"
end
```

`require "kiosk/rls_minitest"` from your `test/test_helper.rb`.

## Wire an executor

The DSL is inert until an executor is configured. Wire `kiosk-server`'s test executor in `test/test_helper.rb`:

```ruby
require "kiosk/rls_minitest"
require "kiosk/server/test_executor"

Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new
```

Until `kiosk-server` ships, use the bundled `NullExecutor` for unit-shaped tests:

```ruby
Kiosk::TestHelpers.executor = Kiosk::TestHelpers::NullExecutor.new
```

## Example

```ruby
require "test_helper"

class OrdersFlowTest < Minitest::Test
  include Kiosk::TestHelpers

  def test_isolates_orders_per_user
    alice = create_user
    bob   = create_user

    as_agent_of(alice) { run_action :create_order, items: ["oranges"] }
    as_agent_of(bob)   { run_action :create_order, items: ["bread"]   }

    as_agent_of(alice) do
      assert_equal [{ "item" => "oranges" }], query("select item from orders")
    end
  end

  def test_denies_anonymous_reads
    as_anonymous do
      assert_rls_denied { query("select * from orders") }
    end
  end
end
```

## Status

Pre-v1.0 alpha. DSL surface and assertions are stable across pre-v1.0 minor bumps.

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [kiosk-test-support](../kiosk-test-support) — shared DSL
- [kiosk-rls-rspec](../kiosk-rls-rspec) — RSpec analogue
