#!/usr/bin/env python3
"""
Kiosk-shipped Argon2id proof-of-work solver.

This script is invoked by an assistant when it receives a `pow_required`
challenge from a Kiosk provider.  It finds the smallest nonce n ≥ 0 such that

    Argon2id(password=str(n), salt=base64decode(challenge.salt),
             m_cost=m, t_cost=t, parallelism=p, hash_len=32, version=19)

has at least `d` leading zero bits, then prints {"nonce": "<n>"}.

Usage:
    python3 solve.py '<challenge json>'
    python3 solve.py  # reads challenge JSON from stdin if no argument given

Challenge JSON schema:
    {
      "salt":   "<base64-encoded raw salt, ≥ 8 bytes>",
      "params": { "m": <KiB>, "t": <iters>, "p": <parallelism>, "d": <bits> }
    }

Dependencies:
    pip install argon2-cffi

The Ruby provider verifies with the same parameters (Argon2::Ext.argon2id_hash_raw
via libargon2, version 0x13).  Both sides produce byte-identical digests —
see `bundle exec rake parity` in the kiosk-pow gem for the automated proof.
"""

import argon2.low_level
import base64
import json
import sys


def leading_zero_bits(data: bytes) -> int:
    """Count leading zero bits from the MSB of byte 0, spanning bytes."""
    count = 0
    for b in data:
        if b == 0:
            count += 8
        else:
            count += 8 - b.bit_length()
            break
    return count


def solve(challenge: dict) -> str:
    """Return the decimal nonce string that satisfies the challenge."""
    salt   = base64.b64decode(challenge["salt"])
    params = challenge["params"]
    m      = int(params["m"])
    t      = int(params["t"])
    p      = int(params["p"])
    d      = int(params["d"])

    nonce = 0
    while True:
        secret = str(nonce).encode("ascii")
        digest = argon2.low_level.hash_secret_raw(
            secret=secret,
            salt=salt,
            time_cost=t,
            memory_cost=m,
            parallelism=p,
            hash_len=32,
            type=argon2.low_level.Type.ID,
            version=19,
        )
        if leading_zero_bits(digest) >= d:
            return str(nonce)
        nonce += 1


def main():
    if len(sys.argv) > 1:
        challenge = json.loads(sys.argv[1])
    else:
        challenge = json.load(sys.stdin)

    nonce = solve(challenge)
    print(json.dumps({"nonce": nonce}))


if __name__ == "__main__":
    main()
