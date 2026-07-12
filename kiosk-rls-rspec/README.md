# kiosk-rls-rspec

RSpec integration for the [Kiosk](https://kiosk.tech) journey-test DSL.

## What it does

Wires the framework-agnostic journey-test DSL (`kiosk-test-support`) into RSpec. Adds:

- `type: :kiosk_journey` metadata — auto-includes the journey helpers (`as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`, `run_action`, `pay_action`, `kiosk_seed`).
- `type: :kiosk_agent` metadata — same DSL today; the optional `kiosk-agent-test` gem later upgrades it to live-LLM mode.
- Matchers: `be_rls_denied`, `be_quota_exceeded`.

## Install

```ruby
group :test do
  gem "kiosk-rls-rspec"
end
```

`require "kiosk/rls_rspec"` from your `spec_helper.rb`. The wiring registers automatically when RSpec is already loaded.

## Wire an executor

The DSL is inert until an executor is configured. Wire `kiosk-server`'s test executor in `spec/spec_helper.rb`:

```ruby
require "kiosk/rls_rspec"
require "kiosk/server/test_executor"

RSpec.configure do |config|
  config.before(:suite) do
    Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new
  end
end
```

For unit-shaped tests that need no live database, use the bundled `NullExecutor` instead:

```ruby
Kiosk::TestHelpers.executor = Kiosk::TestHelpers::NullExecutor.new
```

## Example

```ruby
RSpec.describe "orders flow", type: :kiosk_journey do
  it "isolates orders per user" do
    alice = create_user
    bob   = create_user

    as_agent_of(alice) { run_action :create_order, items: ["oranges"] }
    as_agent_of(bob)   { run_action :create_order, items: ["bread"]   }

    as_agent_of(alice) do
      expect(query("select item from orders")).to contain_exactly("oranges")
    end
  end

  it "denies anonymous reads" do
    as_anonymous do
      expect { query("select * from orders") }.to be_rls_denied
    end
  end
end
```

## Status

Pre-v1.0 alpha. DSL surface and matchers are stable across pre-v1.0 minor bumps.

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [kiosk-test-support](../kiosk-test-support) — shared DSL
- [kiosk-rls-minitest](../kiosk-rls-minitest) — Minitest analogue
