#!/usr/bin/env python3
"""
Equihash PoW solver for Kiosk (default n=168, k=7).

This is a REFERENCE solver: pure Python + numpy. On a consumer laptop the
default params solve in ~10s using ~1.3 GiB (see bench/). Providers pick their
own params; a heavier n means a heavier solve. Not a tuned miner.

Usage:
  python3 solve.py '<json_challenge>'

Challenge JSON: {"salt_b64": "...", "params": {"n": 168, "k": 7}, "header_nonce": 0}
Output JSON:   {"indices": [...], "header_nonce": 0}

Toy mode (for testing):
  python3 solve.py '<json>' --toy    → uses (n=24, k=3), instant
"""
import hashlib
import json
import struct
import sys

try:
    import numpy as np
except ImportError:  # pragma: no cover - guidance path
    sys.stderr.write(
        "ERROR: this solver requires numpy.\n"
        "  pip install numpy\n"
        "The Wagner sort/collide steps are vectorised; without numpy a solve of\n"
        "the default parameters is an order of magnitude slower.\n"
    )
    sys.exit(3)


def blake2b256(data: bytes) -> bytes:
    return hashlib.blake2b(data, digest_size=32).digest()


def hash_nonce(seed: bytes, nonce: int, n: int) -> int:
    """BLAKE2b-256(seed ‖ LE64(nonce)) → first n/8 bytes as big-endian integer."""
    h = blake2b256(seed + struct.pack("<Q", nonce))
    n_bytes = n // 8
    return int.from_bytes(h[:n_bytes], "big")


# ─────────────────────────────────────────────────────────────────────────────
# numpy Wagner solver
#
# The n-bit leaf hash is stored right-aligned across NCOL = ceil(n/64) uint64
# words (word 0 = most significant). Every hot step is vectorised: hashing packs
# into a numpy array, each round sorts by the n_div-bit collision block (native
# radix/quick sort), and XORs/masks run as whole-array ops. This is what keeps a
# consumer laptop and a top-spec bot within the same ballpark — the memory-bound
# sort is native-C either way; only the BLAKE2b floor differs.
# ─────────────────────────────────────────────────────────────────────────────

_U64 = np.uint64


def _ncols(n: int) -> int:
    return (n + 63) // 64


def pack_hashes(seed: bytes, count: int, n: int) -> np.ndarray:
    """Hash nonces 0..count-1 → (count, NCOL) uint64, each row the n-bit hash
    right-aligned big-endian across the words. Hashing is the one step numpy
    cannot vectorise (no batched BLAKE2b), so it is a tight hashlib loop; the
    bytes→uint64 transpose is vectorised."""
    n_bytes = n // 8
    ncol = _ncols(n)
    buf = bytearray(count * n_bytes)
    mv = memoryview(buf)
    bl = hashlib.blake2b
    pk = struct.Struct("<Q").pack
    for i in range(count):
        mv[i * n_bytes:(i + 1) * n_bytes] = bl(seed + pk(i), digest_size=32).digest()[:n_bytes]
    digs = np.frombuffer(bytes(buf), dtype=np.uint8).reshape(count, n_bytes)
    padded = np.zeros((count, ncol * 8), dtype=np.uint8)
    padded[:, ncol * 8 - n_bytes:] = digs          # right-align the n bytes
    words = np.frombuffer(padded.tobytes(), dtype=">u8").reshape(count, ncol)
    return np.ascontiguousarray(words, dtype=_U64)


def block_key(words: np.ndarray, n: int, n_div: int, level: int) -> np.ndarray:
    """Extract collision block `level` (the n_div bits [level*n_div, (level+1)*n_div)
    from the MSB) of every row as a uint64 sort key. n_div ≤ 24 < 64 → a block
    spans at most two adjacent words."""
    ncol = words.shape[1]
    s = n - (level + 1) * n_div          # right-shift within the n-bit value
    mask = _U64((1 << n_div) - 1)
    lo_bit = s % 64
    lo_word = (ncol - 1) - s // 64        # word holding the low end of the block
    lo = words[:, lo_word] >> _U64(lo_bit)
    if lo_bit + n_div <= 64:
        return (lo & mask)
    hi_bits = n_div - (64 - lo_bit)       # bits taken from the more-significant word
    hi = words[:, lo_word - 1] & _U64((1 << hi_bits) - 1)
    return ((hi << _U64(64 - lo_bit)) | lo) & mask


# Max entries per collision bucket that participate in pairing. Healthy buckets
# are Poisson(~2) — a real solution never needs a large one. Deep Wagner levels
# grow degenerate "megabuckets" of index-reusing entries (correlated XORs); left
# unbounded they blow up to C(m,2) ≈ billions of pairs and OOM. Truncating each
# bucket to its first BUCKET_CAP entries bounds work + memory to ~CAP·N and
# discards only that junk; the solution comes from the healthy small buckets.
# (This is the standard production-solver collision cap.)
BUCKET_CAP = 32


def _bucket_pairs(keys: np.ndarray, cap: int = BUCKET_CAP):
    """Within-bucket index pairs (a<b, keys[a]==keys[b]), each bucket truncated
    to its first `cap` members. Fully vectorised: sort once, drop entries whose
    within-bucket rank ≥ cap, then gather equal-key neighbours at each offset d
    (a truncated bucket of size m≤cap is covered by d=1..m-1, so the offset loop
    stops at d=cap)."""
    order = np.argsort(keys, kind="stable")
    sk = keys[order]
    m = len(sk)
    if m < 2:
        return np.empty(0, np.int64), np.empty(0, np.int64)

    # within-bucket rank of each (sorted) element
    change = np.empty(m, dtype=bool)
    change[0] = True
    np.not_equal(sk[1:], sk[:-1], out=change[1:])
    starts = np.nonzero(change)[0]
    bucket_id = np.cumsum(change) - 1
    rank = np.arange(m) - starts[bucket_id]
    keep = rank < cap
    sk = sk[keep]
    order = order[keep]

    a_parts, b_parts = [], []
    d = 1
    while d < len(sk):
        same = sk[:-d] == sk[d:]
        pos = np.nonzero(same)[0]
        if pos.size == 0:
            break
        a_parts.append(order[pos])
        b_parts.append(order[pos + d])
        d += 1
    if not a_parts:
        return np.empty(0, np.int64), np.empty(0, np.int64)
    return np.concatenate(a_parts), np.concatenate(b_parts)


def solve_equihash(seed: bytes, n: int, k: int):
    """Find one Equihash solution for (seed, n, k), or None. Returns the 2^k
    leaf indices in Zcash-canonical (tree) order — the order the verifier wants
    (NOT globally sorted)."""
    n_div = n // (k + 1)
    N = 1 << (n_div + 1)                   # standard pool: ~2 entries per bucket

    words = pack_hashes(seed, N, n)        # level-0 hashes; entry i ≡ nonce i
    # uint32 everywhere the row-count fits (N < 2^32) to keep peak RSS down: at
    # the default n=168 the arrays are 2^22 rows, so every int64→uint32 saves
    # tens of MB; at larger n the saving grows.
    mins = np.arange(N, dtype=np.uint32)   # min leaf index per entry (for ordering)
    tree = []                              # tree[L] = (left_pos, right_pos) into level L

    for level in range(k):
        keys = block_key(words, n, n_div, level)
        a, b = _bucket_pairs(keys)         # int64 row indices
        if a.size == 0:
            return None
        a = a.astype(np.uint32, copy=False)
        b = b.astype(np.uint32, copy=False)
        # New entry = XOR of the pair (cancels this block).
        new_words = words[a] ^ words[b]
        ma, mb = mins[a], mins[b]
        # Canonical ordering: the subtree with the smaller min index goes left.
        a_left = ma < mb
        tree.append((np.where(a_left, a, b), np.where(a_left, b, a)))
        words = new_words
        mins = np.minimum(ma, mb)
        del keys, a, b, ma, mb, a_left       # release the level's temporaries

    # Solutions: full value == 0 (all words zero → every block cancelled).
    sol_rows = np.nonzero((words == 0).all(axis=1))[0]
    for row in sol_rows:
        idx = _reconstruct(tree, k, int(row))
        if len(set(idx)) == len(idx):      # distinct-index rule
            return idx
    return None


def _reconstruct(tree, level, pos):
    """Expand entry `pos` at `level` into its leaf indices, left-to-right.
    Because each node stored (left, right) with left = smaller-min subtree, the
    left-to-right walk yields Zcash-canonical order directly."""
    if level == 0:
        return [pos]                        # level-0 entry i ≡ nonce i
    lft, rgt = tree[level - 1]
    return _reconstruct(tree, level - 1, int(lft[pos])) + \
        _reconstruct(tree, level - 1, int(rgt[pos]))


def verify_solution(seed: bytes, indices: list, n: int, k: int) -> bool:
    """
    Verify a candidate solution — the SAME contract as the Ruby verifier
    Kiosk::Pow::Equihash.verify (Zcash-canonical Equihash):

      * 2^k distinct, non-negative indices;
      * global XOR of all leaf hashes == 0 on n bits;
      * at each level j, every group of 2^(j+1) leaves has its XOR CANCEL the
        top (j+1)*n_div bits (Wagner cancellation — leaves are NOT equal on the
        prefix, only their XOR is);
      * canonical order: at each node the left half's first index precedes the
        right half's (Zcash algorithm binding) — NOT a global sort.
    """
    n_div = n // (k + 1)
    n_bytes = n // 8
    expected_len = 1 << k

    if len(indices) != expected_len:
        return False
    if len(set(indices)) != expected_len or any(i < 0 for i in indices):
        return False

    hash_vals = [int.from_bytes(blake2b256(seed + struct.pack("<Q", idx))[:n_bytes], "big")
                 for idx in indices]

    xor_all = 0
    for v in hash_vals:
        xor_all ^= v
    if xor_all != 0:
        return False

    for level in range(k):
        group_size = 1 << (level + 1)
        num_groups = expected_len // group_size
        prefix_shift = n - (level + 1) * n_div
        half = group_size // 2

        for g in range(num_groups):
            base = g * group_size
            group_xor = 0
            for i in range(group_size):
                group_xor ^= hash_vals[base + i]
            if (group_xor >> prefix_shift) != 0:
                return False
            if indices[base] >= indices[base + half]:
                return False

    return True


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: solve.py '<json_challenge>' [--toy]"}))
        sys.exit(1)

    challenge = json.loads(sys.argv[1])
    toy = "--toy" in sys.argv

    # Accept both `salt_b64` and the gate/challenge wire key `salt`.
    salt_b64 = challenge.get("salt_b64") or challenge["salt"]
    params = challenge.get("params", {})
    n = params.get("n", 24 if toy else 168)
    k = params.get("k", 3 if toy else 7)
    start_nonce = challenge.get("header_nonce", 0)

    import base64
    salt = base64.b64decode(salt_b64)

    # Each header_nonce is an independent attempt; a proper Wagner pass finds a
    # solution with ~constant probability per seed, so this rarely loops more
    # than a few times.
    max_attempts = 256
    for attempt in range(max_attempts):
        header_nonce = start_nonce + attempt
        seed = salt + struct.pack("<I", header_nonce)
        solution = solve_equihash(seed, n, k)
        if solution is not None and verify_solution(seed, solution, n, k):
            print(json.dumps({"indices": solution, "header_nonce": header_nonce}))
            return

    print(json.dumps({"error": f"no solution found after {max_attempts} attempts"}))
    sys.exit(2)


if __name__ == "__main__":
    main()
