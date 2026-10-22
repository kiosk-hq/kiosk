# kiosk-pow

The base of the proof-of-work backends of the [Kiosk](https://kiosk.tech) framework.

A backend verifies one proof of work for one algorithm. kiosk-pow holds the code
that the backends share:

- `Kiosk::Pow::Blake2b.digest256(input)` returns the BLAKE2b-256 digest of
  `input` (RFC 7693, no key, 32 raw bytes). It is pure Ruby. Its spec compares it
  with Python's `hashlib.blake2b(data, digest_size=32)`, on inputs at both sides
  of the 128-byte block.
- `Kiosk::Pow.param(hash, key)` reads one key of a protocol object. Parsed JSON has
  String keys and Ruby callers use Symbols; it reads both.

kiosk-pow is pure Ruby. It has no runtime dependencies, and it does not need
`kiosk-core` or Rails.

## The backends

| Gem | `alg` | Status |
|-----|-------|--------|
| `kiosk-pow-equihash` | `equihash` | The shipped default. Registers itself in a Rails app. |
| `kiosk-pow-cuckoo` | `cuckatoo` | Opt-in. The host registers it. |
| `kiosk-pow-argon2id` | `argon2id` | Legacy. The host registers it. |

`kiosk-reputation` holds the registry. It mints and signs each challenge, and it
checks the signature and the expiry before it calls a backend.

## How to add a backend

A backend is a Ruby module. It verifies one proof against one challenge.
`kiosk-reputation` does all the other work.

### 1. Make the gem

Name the gem `kiosk-pow-<algorithm>`. Make it depend on `kiosk-pow`:

```ruby
spec.add_dependency 'kiosk-pow', '~> 0.6.0'
```

### 2. Define the module

Require `kiosk/pow`. Define the module under `Kiosk::Pow`:

```ruby
require 'kiosk/pow'

module Kiosk
  module Pow
    module Example
      NAME = 'example'

      def self.params(bits: 20) = { bits: }

      def self.verify(salt:, params:, nonce:)
        bits  = Integer(Pow.param(params, :bits))
        value = Pow.param(nonce, :value)
        return false unless value.is_a?(Integer) && value.between?(0, (1 << 64) - 1)

        digest = Blake2b.digest256(salt + [value].pack('Q<'))
        digest.unpack1('B*').start_with?('0' * bits)
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
```

### 3. Give the module these members

| Member | Required | What it does |
|--------|----------|--------------|
| `NAME` | Yes | The `alg` string of the signed challenge. |
| `.params(**)` | Yes | Returns the `params` Hash of a challenge. The host calls it when it writes its policy. |
| `.verify(salt:, params:, nonce:)` | Yes | Returns `true` when `nonce` is a valid proof for `salt` and `params`. Returns `false` for all other input. |
| `.valid_params?(params)` | No | Returns `false` when no proof can verify at `params`. `kiosk-server`'s PoW toll calls it through `Kiosk::Reputation::Backends.valid_params?` before it mints a challenge. A wrong configuration then fails at once. |

### 4. Read the inputs of `.verify` correctly

- `salt` is raw bytes. `kiosk-reputation` decodes the base64 of the protocol.
- `params` is the signed `params` of the challenge, with Symbol keys.
- `nonce` is the `nonce` of the proof, as the `Kiosk-PoW` header carries it. It
  is parsed JSON, so its keys are Strings. Read it with `Kiosk::Pow.param`.
- Each key and each value of `params` must not contain `|`, `,` or `=`. These
  characters separate the fields of the signed string, and `kiosk-reputation`
  refuses such a challenge.

### 5. Make a wrong proof cheap to refuse

`.verify` runs before authentication on `POST /kiosk/oauth/register`. Anyone can
send it a proof. So:

- Check the shape and the bounds of the proof first. Compute hashes last.
- Return `false` at the first check that fails.
- Do not raise an exception for any input. Return `false`.
- Keep the memory and the time of one verify small.

### 6. Hash with the shared BLAKE2b

When the algorithm uses BLAKE2b-256, call `Kiosk::Pow::Blake2b.digest256`. Do not
add a second BLAKE2b implementation.

### 7. Register the backend

Register the module under its `NAME`:

```ruby
Kiosk::Reputation::Backends.register(Kiosk::Pow::Example::NAME, Kiosk::Pow::Example)
```

A Rails app can do this at boot. `kiosk-pow-equihash` does it with a Railtie:

```ruby
class Railtie < Rails::Railtie
  initializer 'kiosk_pow_example.register_backend' do
    require 'kiosk/reputation/backends'
    Kiosk::Reputation::Backends.register(NAME, Example)
  end
end
```

The policy then names the algorithm in each challenge:
`{ alg: 'example', params: Kiosk::Pow::Example.params }`.

### 8. Tell the assistants how to solve it

The specification lets an operator serve an `alg` that it does not define. The
backend brings its own `nonce` encoding. The Kiosk skill teaches assistants to
solve Equihash only. If you serve another `alg`, give the assistants a solver and
tell them the `nonce` encoding yourself.

### 9. Test the backend

- Write known-answer tests at the parameters that you ship. A test at small
  parameters only does not prove the shipped parameters.
- Take one known answer from an independent implementation.
- When you ship a solver, run it in a test and verify its proof in Ruby.
- Test that each malformed proof returns `false` and does not raise.

## Installation

A backend gem brings `kiosk-pow` with it. Add it yourself only when you write a
backend in your own app:

```ruby
gem "kiosk-pow"
```

## License

Apache-2.0. See [LICENSE.txt](LICENSE.txt).
