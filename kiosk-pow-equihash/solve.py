#!/usr/bin/env python3
"""
Equihash PoW solver for Kiosk (n=192, k=7, ~1 GiB RAM).

Usage:
  python3 solve.py '<json_challenge>'

Challenge JSON: {"salt_b64": "...", "params": {"n": 192, "k": 7}, "header_nonce": 0}
Output JSON:   {"indices": [...], "header_nonce": 0}

Toy mode (for testing):
  python3 solve.py '<json>' --toy    → uses (n=24, k=3), instant
"""
import hashlib
import json
import struct
import sys


def blake2b256(data: bytes) -> bytes:
    return hashlib.blake2b(data, digest_size=32).digest()


def hash_nonce(seed: bytes, nonce: int, n: int) -> int:
    """BLAKE2b-256(seed ‖ LE64(nonce)) → first n/8 bytes as big-endian integer."""
    h = blake2b256(seed + struct.pack("<Q", nonce))
    n_bytes = n // 8
    return int.from_bytes(h[:n_bytes], "big")


def solve_equihash(seed: bytes, n: int, k: int, pool_extra: int = 0):
    """
    Wagner's algorithm for Equihash.

    Entry format: (combined_xor, *nonces) where combined_xor is the XOR
    of all constituent nonce hashes masked to n bits.

    pool_extra: additional bits for the initial pool size (default 0 = 2^(n_div+1)).
                Use 2-4 for small n/k to compensate for greedy pairing losses.

    Returns sorted list of 2^k nonces, or None if no solution found.
    """
    n_div = n // (k + 1)
    num_entries = 1 << (n_div + 1 + pool_extra)
    n_bytes = n // 8
    n_mask = (1 << n) - 1

    # Level 0: individual nonces
    entries = []
    for nonce in range(num_entries):
        h = blake2b256(seed + struct.pack("<Q", nonce))
        val = int.from_bytes(h[:n_bytes], "big")
        entries.append((val, nonce))

    entries.sort(key=lambda x: x[0])
    current = entries

    # Wagner collision search: k levels (0 .. k-1)
    for level in range(k):
        coll_bits = (level + 1) * n_div
        coll_mask = n_mask ^ ((1 << (n - coll_bits)) - 1)

        next_level = []
        i = 0
        while i < len(current):
            prefix = current[i][0] & coll_mask
            j = i + 1
            while j < len(current) and (current[j][0] & coll_mask) == prefix:
                j += 1
            group = current[i:j]
            if len(group) >= 2:
                for p in range(0, len(group) - 1, 2):
                    new_xor = (group[p][0] ^ group[p + 1][0]) & n_mask
                    new_nonces = sorted(group[p][1:] + group[p + 1][1:])
                    next_level.append((new_xor, *new_nonces))
            i = j

        if not next_level:
            return None

        next_level.sort(key=lambda x: x[0])
        current = next_level

    # After k levels: find entry with combined_xor == 0
    for entry in current:
        if entry[0] == 0:
            return sorted(entry[1:])

    return None


def verify_solution(seed: bytes, indices: list, n: int, k: int) -> bool:
    """
    Verify that a candidate solution satisfies the Equihash collision tree.
    Mirrors the Ruby verifier: 2^k indices, XOR=0, tree structure.
    """
    n_div = n // (k + 1)
    n_bytes = n // 8
    expected_len = 1 << k

    if len(indices) != expected_len:
        return False

    # Strictly ascending, no duplicates
    for i in range(1, len(indices)):
        if indices[i] <= indices[i - 1]:
            return False

    # Compute hashes
    hash_vals = []
    for idx in indices:
        h = blake2b256(seed + struct.pack("<Q", idx))
        val = int.from_bytes(h[:n_bytes], "big")
        hash_vals.append(val)

    # Global XOR must be zero
    xor_all = 0
    for v in hash_vals:
        xor_all ^= v
    if xor_all != 0:
        return False

    # Collision tree: level j, groups of 2^(j+1) collide on (j+1)*n_div bits
    for level in range(k):
        group_size = 1 << (level + 1)
        num_groups = expected_len // group_size
        prefix_shift = n - (level + 1) * n_div

        for g in range(num_groups):
            base = hash_vals[g * group_size] >> prefix_shift
            for i in range(1, group_size):
                if (hash_vals[g * group_size + i] >> prefix_shift) != base:
                    return False

    return True


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: solve.py '<json_challenge>' [--toy]"}))
        sys.exit(1)

    challenge = json.loads(sys.argv[1])
    toy = "--toy" in sys.argv

    salt_b64 = challenge["salt_b64"]
    params = challenge["params"]
    n = params.get("n", 24 if toy else 192)
    k = params.get("k", 3 if toy else 7)
    start_nonce = challenge.get("header_nonce", 0)

    # Auto-tune pool_extra for small n/k: greedy pairing needs more entries
    n_div = n // (k + 1)
    if n_div <= 8:
        pool_extra = 4  # 16x pool for n_div ≤ 8
    elif n_div <= 12:
        pool_extra = 2  # 4x pool for n_div ≤ 12
    else:
        pool_extra = 0  # production: default pool is sufficient

    import base64
    salt = base64.b64decode(salt_b64)

    # Retry with incrementing header_nonce until a valid solution is found
    max_attempts = 10000
    for attempt in range(max_attempts):
        header_nonce = start_nonce + attempt
        seed = salt + struct.pack("<I", header_nonce)
        solution = solve_equihash(seed, n, k, pool_extra=pool_extra)
        if solution is not None and verify_solution(seed, solution, n, k):
            print(json.dumps({
                "indices": solution,
                "header_nonce": header_nonce,
            }))
            return

    print(json.dumps({"error": f"no solution found after {max_attempts} attempts"}))
    sys.exit(2)


if __name__ == "__main__":
    main()
