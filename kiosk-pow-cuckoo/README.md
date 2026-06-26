# kiosk-pow-cuckoo

Cuckatoo-Cycle proof-of-work backend for [Kiosk](https://kiosk.tech).

## What this is

An optional PoW backend with a large solve:verify asymmetry — solving requires
finding a 42-cycle in a large random bipartite graph (gigabytes of RAM, seconds
of CPU), while verifying is 42 SipHash evaluations plus a cycle-walk (~10 μs).

This gem ships **the verifier only** (T1).  A solver is a separate component.

## Algorithm: Cuckatoo Cycle

- Graph size: `N = 2^edgebits` nodes on each side of the bipartite graph
- Edge `i` connects `U(i) = siphash(2i) mod N` to `V(i) = siphash(2i+1) mod N`
- Proof: 42 strictly-ascending edge indices forming a single cycle
- Keys: `blake2b-256(header)` split into four LE-u64 words

SipHash uses Cuckatoo's **non-standard initialization** (keys feed directly into
`v0..v3` without XOR-ing the 0x736f6d65... magic constants from the standard
SipHash spec).

## Implementation

- **BLAKE2b-256**: pure Ruby from the public-domain [BLAKE2 spec](https://www.blake2.net/blake2.pdf).
- **SipHash-2-4**: pure Ruby from the [public-domain SipHash spec](https://131002.net/siphash/siphash.pdf),
  with Cuckatoo's non-standard init.
- No native extensions, no GPL code, no Tromp repository code.
- License: Apache-2.0.

## Known-answer validation

The verifier is validated against Grin's Cuckatoo29 CI test vector:
- `edgebits=29`, header = 80 zero bytes keyed with `nonce=20`
- 42-cycle accepted; five categories of bad inputs rejected

## API

```ruby
# Challenge params
params = Kiosk::Pow::Cuckoo.params(edgebits: 29)
# => { edgebits: 29, proofsize: 42, target: nil }

# Verify a proof (composite nonce: header_nonce + cycle)
Kiosk::Pow::Cuckoo.verify(
  salt:   raw_salt_bytes,
  params: params,
  nonce:  { header_nonce: 20, cycle: [e0, e1, ..., e41] }
)
# => true / false

# Lower-level: verify cycle with pre-derived keys
keys = Kiosk::Pow::Cuckoo.blake2b256(header).unpack("Q<4")
Kiosk::Pow::Cuckoo.verify_cycle(keys: keys, edgebits: 29, cycle: cycle)
```

## Difficulty target

An optional `target` (Integer, 256-bit) can be added to params to tighten
difficulty beyond the base cycle requirement:

```ruby
params = Kiosk::Pow::Cuckoo.params(edgebits: 29, target: (2**256 - 1) / 100)
```

When set, the verifier additionally checks:
```
blake2b-256(sorted_cycle_edges_as_LE_u64) < target
```

## Caveats

- Cuckatoo is NOT ASIC-proof (1 GB-SRAM ASICs exist for edgebits=31+).  The
  provider mandates it; clients that cannot solve are denied.  This is
  intentional: it raises the cost of abuse.
- `edgebits < 19` is suitable only for testing; production uses edgebits ≥ 29.
